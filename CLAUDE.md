# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Onesies is a collection of self-contained, single-file tools designed for portability and simplicity.

### Core Principles

- **Single File Rule**: Every tool must be fully contained in one source file
- **No Dependencies**: Tools should only rely on standard system programs and commonly available utilities
- **Cross-Platform**: Must work on typical Linux and macOS systems, Docker containers
- **Easy Installation**: Copy one file to install anywhere

### Standard Programs Available

Assume these are installed by default:
- Shell (bash, sh, zsh)
- Core utilities (grep, sed, awk, cut, sort, etc.)
- Git
- Perl (version bundled with Git)
- Python (system version)
- Standard text editors (vi/vim, nano)

### Tool Categories

1. **cli/**: Command-line tools (shell script or perl preferred)
2. **macos/**: macOS desktop apps (AppleScript or Swift with shebang)
3. **userscripts/**: Browser console JavaScript snippets

## Development Guidelines

### CLI Tools
- Use shell script or perl (no external deps beyond Git's perl)
- If bash: always enable strict mode (`set -euo pipefail`)
- Follow Unix philosophy: do one thing well
- Support both interactive and scripted use

### macOS Tools
- Use AppleScript or Swift with `#!/usr/bin/osascript` or `#!/usr/bin/swift`
- Must be executable from terminal
- Ensure Ctrl+C terminates cleanly
- No compile step or IDE required

### Userscripts
- Pure JavaScript for browser dev console
- No external dependencies
- Enhance existing page functionality

## Tool Documentation Requirements

**IMPORTANT**: When creating any new tool, you MUST update the README.md file:

1. **Add tool entry**: Include the new tool in the "Available Tools" section under the appropriate category
2. **Brief description**: Provide a concise description highlighting the tool's key features or unique aspects
3. **Format**: Use format `**\`toolname\`** - Brief description of functionality and notable features`

### Examples of Good Tool Descriptions:
- **`hello`** - Bash greeting tool with options for uppercase, timestamps, and custom names
- **`hello-perl`** - Perl greeting tool demonstrating POD documentation and core module usage
- **`hello-swift`** - Native Cocoa app with GUI form, checkboxes, and real-time greeting updates

This ensures users can quickly discover and understand available tools without having to examine source code.

## Anchor Comments

Add specially formatted comments throughout the codebase, where appropriate, for yourself as inline knowledge that can be easily `grep`ped for.

*Credit: This pattern is from Diwank Singh's article "Field Notes from Shipping Real Code with Claude" (https://diwank.space/field-notes-from-shipping-real-code-with-claude)*

### Guidelines:

- Use `AIDEV-NOTE:`, `AIDEV-TODO:`, or `AIDEV-QUESTION:` (all-caps prefix) for comments aimed at AI and developers.
- **Important:** Before scanning files, always first try to **grep for existing anchors** `AIDEV-*` in relevant subdirectories.
- **Update relevant anchors** when modifying associated code.
- **Do not remove `AIDEV-NOTE`s** without explicit human instruction.
- Make sure to add relevant anchor comments, whenever a file or piece of code is:
  * too complex, or
  * very important, or
  * confusing, or
  * could have a bug

## Configuration Best Practices

- In each script, ensure config a user may want to change is towards the top, and easy to understand. for example, key bindings, default values, timeouts, etc.

## Development Process Requirements

**CRITICAL**: Before any commit, you MUST update this CLAUDE.md file with lessons learned from the development process. This ensures institutional knowledge is captured and future development benefits from past experience.

## General Development Lessons

**1. Configuration Architecture**
- Store values in their base units to avoid precision loss
- Use `var` instead of `let` for CLI-configurable values
- Group related config in a clear struct/section at the top of the file
- Provide commented examples of alternative configurations

**2. CLI Design Patterns**
- Always include testing-friendly options for development (short durations, quick iterations)
- Use flexible input parsing (multiple formats: 25m, 90s, 1.5m)
- Provide comprehensive help with usage examples
- Give immediate feedback on configuration parsing errors

**3. User Experience**
- Use monospace fonts for displays that change frequently to prevent UI jumping
- Apply clear visual hierarchy (muted for normal, bright for important states)
- Include startup messages that guide proper usage patterns
- Make help text include best practices for the tool type

**4. Documentation Structure**
- Keep screenshots in dedicated directory to maintain clean repo structure
- Use "Featured Tools" section to highlight main capabilities
- Always update README.md with new tool entries (per existing requirements)

**5. Code Migration Patterns**
- Always add comprehensive configuration section at top when migrating existing tools
- Preserve original functionality while applying Onesies standards
- Add AIDEV-NOTE comments to mark configuration sections
- Include startup guidance messages for better user onboarding
- Use accessory app policy for menu bar tools (no dock icon)

**6. Network & Protocol Handling in Single-File Tools**
- Swift's `Network` framework (`NWListener`) works in shebang scripts and provides zero-dependency TCP server capability
- For HTTP parsing on raw TCP, split on `\r\n\r\n` for header/body separation and use `Content-Length` for body framing
- Always send response before cancelling connection (`send` then `cancel` in completion handler)
- Use `DispatchQueue.main.async` for thread-safe UI updates from network callbacks
- OTLP JSON can be parsed with `JSONSerialization` - avoids needing Codable structs for deeply nested protocol structures
- Debug logging of first payload per source type is invaluable for validating protocol assumptions

**7. OpenTelemetry Integration Patterns**
- Both Claude Code and Codex CLI support OTLP HTTP JSON export for token usage tracking
- Claude Code: set `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_LOGS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`
- OTLP attributes use a verbose format: `[{"key": "foo", "value": {"stringValue": "bar"}}]` - parse into flat dict for convenience
- `intValue` in OTLP can be either a string or integer depending on the sender - handle both
- Bind listener to loopback only (`NWEndpoint.hostPort(host: .ipv4(.loopback), port:)`) for security

**8. Persistence & Animation in Menu Bar Tools**
- Use `~/.config/<tool-name>/data.json` for simple JSON persistence (follows XDG conventions)
- Use `FileManager.default.createDirectory(withIntermediateDirectories: true)` and explicit `do/catch` (not `try?`) so save failures are visible
- Use `JSONSerialization` for persistence to stay consistent with OTLP parsing style
- Write atomically (`.atomic` option) to prevent corruption from interrupted writes
- For menu bar animations, use a custom `NSView` subview on `statusItem.button` with `draw(_ dirtyRect:)` override
- Cubic ease-out (`1 - (1-t)^3`) provides satisfying count-up: fast start, gentle landing
- Keep animation short (~0.6s at ~30fps) to feel responsive without being distracting
- Use `onUpdate` callbacks rather than polling to trigger animations when data changes

**9. Custom Chart Rendering in Menu Bar Apps**
- Use `NSView` subclasses with `draw(_ dirtyRect:)` for charts in NSMenu items
- `NSBezierPath(roundedRect:xRadius:yRadius:)` for bars with rounded corners
- Clip to rounded rect (`addClip()`) before drawing stacked segments for clean bar ends
- Always `saveGraphicsState()`/`restoreGraphicsState()` around clip operations
- Use `NSColor.system*` colors (systemBlue, systemOrange, etc.) for automatic dark/light mode
- `NSColor.separatorColor.withAlphaComponent(0.15)` is idiomatic for subtle background tracks
- Bucket time-series data into fixed slots and show only a few axis labels to avoid clutter
- Size chart views to fit menu dropdown width (~260px) with standard 14px insets