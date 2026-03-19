#!/bin/bash
set -e

# POC: Automated upstream sync using pi-ast + ast-grep
# Usage: ./sync-patch.sh

REPO_DIR="${1:-/tmp/pi-mono-test}"
PACKAGE_FILE="$REPO_DIR/packages/coding-agent/src/core/package-manager.ts"
TEST_FILE="$REPO_DIR/packages/coding-agent/test/package-manager.test.ts"
RULES_DIR=$(mktemp -d)

echo "=== Step 1: Find functions with pi-ast ==="
pi-ast register_project_tool path="$REPO_DIR" name=sync-test > /dev/null 2>&1

INSTALLED_LINE=$(pi-ast get_symbols project=sync-test file_path=packages/coding-agent/src/core/package-manager.ts | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f['location']['start']['row']) for f in d['functions'] if f['name']=='installedNpmMatchesPinnedVersion']")

GET_LATEST_LINE=$(pi-ast get_symbols project=sync-test file_path=packages/coding-agent/src/core/package-manager.ts | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(f['location']['start']['row']) for f in d['functions'] if f['name']=='getLatestNpmVersion']")

echo "  installedNpmMatchesPinnedVersion at line $INSTALLED_LINE"
echo "  getLatestNpmVersion at line $GET_LATEST_LINE"

echo ""
echo "=== Step 2: Verify functions exist with ast-grep ==="
FOUND=$(sg scan --inline-rules "id: verify
language: typescript
rule:
  kind: method_definition
  has:
    field: name
    regex: getLatestNpmVersion|installedNpmMatchesPinnedVersion" "$PACKAGE_FILE" 2>&1 | grep -c "help\[" || true)

echo "  Found $FOUND function matches"

if [ "$FOUND" -ne 2 ]; then
  echo "  ERROR: Expected 2 matches, got $FOUND"
  exit 1
fi

echo ""
echo "=== Step 3: Apply ast-grep fixes ==="

# Rule 1: installedNpmMatchesPinnedVersion - add dist-tag resolution
cat > "$RULES_DIR/rule1.yaml" << 'RULE1'
id: fix-installedNpmMatches
language: typescript
rule:
  kind: method_definition
  has:
    field: name
    regex: installedNpmMatchesPinnedVersion
fix: |2
    private async installedNpmMatchesPinnedVersion(source: NpmSource, installedPath: string): Promise<boolean> {
      const installedVersion = this.getInstalledNpmVersion(installedPath);
      if (!installedVersion) {
        return false;
      }

      const { version: pinnedVersion } = this.parseNpmSpec(source.spec);
      if (!pinnedVersion) {
        return true;
      }

      if (!pinnedVersion.includes(".")) {
        try {
          const resolvedVersion = await this.getLatestNpmVersion(source.name, pinnedVersion);
          return resolvedVersion === installedVersion;
        } catch {
          return false;
        }
      }

      return installedVersion === pinnedVersion;
    }
RULE1

sg scan -r "$RULES_DIR/rule1.yaml" -U "$PACKAGE_FILE"
echo "  Applied dist-tag resolution fix"

# Rule 2: getLatestNpmVersion - async npm view with timeout
cat > "$RULES_DIR/rule2.yaml" << 'RULE2'
id: fix-getLatestNpmVersion
language: typescript
rule:
  kind: method_definition
  has:
    field: name
    regex: getLatestNpmVersion
fix: |2
    private async getLatestNpmVersion(packageName: string, tag = "latest"): Promise<string> {
      const result = await this.runCommandCapture("npm", ["view", packageName + "@" + tag, "version"], {
        timeoutMs: NETWORK_TIMEOUT_MS,
      });
      if (!result) throw new Error("No version found for " + packageName + "@" + tag);
      return result.trim();
    }
RULE2

sg scan -r "$RULES_DIR/rule2.yaml" -U "$PACKAGE_FILE"
echo "  Applied async npm view fix"

echo ""
echo "=== Step 4: Update test file ==="

# Rule 3: Update the test to mock runCommandCapture instead of fetch
cat > "$RULES_DIR/rule3.yaml" << 'RULE3'
id: fix-test
language: typescript
rule:
  kind: call_expression
  has:
    field: function
    kind: member_expression
  pattern: $OBJ.mockResolvedValue($ARG)
  inside:
    kind: variable_declarator
    has:
      field: name
      regex: fetchMock
RULE3

# For the test file, use grep-based approach since ast-grep pattern is complex
# Find the test and replace it
cd "$REPO_DIR"

# Use pi-ast to find the test function location
TEST_LINE=$(pi-ast get_symbols project=sync-test file_path=packages/coding-agent/test/package-manager.test.ts | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('functions', []):
    if 'AbortSignal' in f.get('name', '') or f.get('name', '') == '':
        pass
# Just find test blocks near line 1402
" 2>/dev/null || echo "1402")

echo "  Test file located, applying sed-based fix for now"

# Simple sed replacement for the test (ast-grep pattern too complex)
# This replaces the fetch-based test with a runCommandCapture-based test
python3 << 'PYEOF'
import re

with open("packages/coding-agent/test/package-manager.test.ts", "r") as f:
    content = f.read()

old_test = '''		it("should pass an AbortSignal timeout when fetching npm latest version", async () => {
			const fetchMock = vi.fn().mockResolvedValue({
				ok: true,
				json: async () => ({ version: "1.2.3" }),
			});
			vi.stubGlobal("fetch", fetchMock);

			const latest = await (packageManager as any).getLatestNpmVersion("example");
			expect(latest).toBe("1.2.3");
			expect(fetchMock).toHaveBeenCalledTimes(1);

			const [, options] = fetchMock.mock.calls[0] as [string, RequestInit | undefined];
			expect(options?.signal).toBeDefined();
		});'''

new_test = '''		it("should pass a timeout when fetching npm latest version", async () => {
			const captureMock = vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue("1.2.3");

			const latest = await (packageManager as any).getLatestNpmVersion("example");
			expect(latest).toBe("1.2.3");
			expect(captureMock).toHaveBeenCalledTimes(1);

			const [, args, options] = captureMock.mock.calls[0] as [string, string[], { timeoutMs?: number }];
			expect(args).toEqual(["view", "example@latest", "version"]);
			expect(options?.timeoutMs).toBeDefined();
		});'''

if old_test in content:
    content = content.replace(old_test, new_test)
    with open("packages/coding-agent/test/package-manager.test.ts", "w") as f:
        f.write(content)
    print("  Applied test fix")
else:
    print("  WARNING: Could not find test pattern, may already be fixed or pattern changed")
PYEOF

echo ""
echo "=== Step 5: Verify changes ==="
echo "  Checking diff..."
git diff --stat packages/coding-agent/src/core/package-manager.ts packages/coding-agent/test/package-manager.test.ts

echo ""
echo "=== Done ==="
echo "  Changes applied. Run 'npm run build && npm test' to verify."
echo "  Temp rules dir: $RULES_DIR"
