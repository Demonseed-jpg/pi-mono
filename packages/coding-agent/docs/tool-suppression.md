# Tool Suppression & Custom Working Text

Tools can optionally hide themselves from the UI and customize the "Working..." status message shown during execution.

## Properties

Add these optional properties to your tool definition:

| Property | Type | Description |
|----------|------|-------------|
| `suppress` | `"enable"` | Hides the tool from appearing in the UI during execution |
| `workingText` | `string` | Shows a custom status message below the main "Working..." loader |

## Example

```typescript
import { Type } from "@sinclair/typebox";

pi.registerTool({
  name: "background_sync",
  label: "Background Sync",
  description: "Syncs data in the background",
  parameters: Type.Object({}),

  // Hide this tool from the UI
  suppress: "enable",

  // Show custom status text while running
  workingText: "Syncing data...",

  async execute(toolCallId, params, signal, onUpdate, ctx) {
    // ... tool logic
    return {
      content: [{ type: "text", text: "Sync complete" }],
      details: {},
    };
  },
});
```

## Use Cases

**`suppress`** — Use for background/internal tools that don't benefit from visual feedback:
- File watchers
- State persistence
- Background analytics
- Logging/metrics

**`workingText`** — Use for long-running tools where generic "Working..." isn't informative:
- "Analyzing codebase..."
- "Fetching data..."
- "Building project..."

## Notes

- Both properties are **opt-in** — only tools that declare them will use them
- The `workingText` appears as a **separate loader** below the main "Working..." message
- The custom loader is automatically removed when tool execution completes
- Works in both TUI and web-ui (suppression applies to both)
