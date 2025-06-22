# Onesies

A collection of self-contained, single-file tools for everyday computing tasks.

## Philosophy

Each tool in this repository follows a simple principle: **one file, one tool, no dependencies**. Every tool can be installed by copying a single file to your system.

## Tool Categories

### 📟 CLI Tools (`cli/`)
Command-line utilities that follow Unix philosophy. Written in shell script or perl.

**Requirements:**
- Must work on Linux and macOS
- Use only standard system programs
- Enable bash strict mode when using bash
- Support both interactive and scripted usage

### 🖥️ macOS Tools (`macos/`)
Desktop applications for macOS written in AppleScript or Swift.

**Requirements:**
- Executable with shebang (`#!/usr/bin/osascript` or `#!/usr/bin/swift`)
- Runnable from terminal
- Handle Ctrl+C gracefully
- No compilation or IDE required

### 🌐 Userscripts (`userscripts/`)
JavaScript snippets for enhancing web pages via browser developer console.

**Requirements:**
- Pure JavaScript (no external dependencies)
- Paste and run in any browser's dev console
- Enhance existing page functionality

## Installation

Copy any tool file to your system and make it executable:

```bash
# CLI tools
cp cli/toolname ~/bin/toolname
chmod +x ~/bin/toolname

# macOS tools
cp macos/toolname ~/bin/toolname
chmod +x ~/bin/toolname

# Userscripts
# Copy and paste into browser developer console
```

## Standard Environment

Tools assume these programs are available:
- Shell (bash, sh, zsh)
- Core utilities (grep, sed, awk, cut, sort, uniq, etc.)
- Git
- Perl (bundled with Git)
- Python (system version)
- Standard text editors (vi/vim, nano)

## Contributing

When adding new tools:

1. **One file rule**: Entire tool must be in a single file
2. **No external dependencies**: Use only standard system programs
3. **Cross-platform**: Test on both Linux and macOS
4. **Documentation**: Include usage examples in comments
5. **Error handling**: Handle edge cases gracefully

## Available Tools

### CLI Tools

- **`hello`** - Bash greeting tool with options for uppercase, timestamps, and custom names
- **`hello-perl`** - Perl greeting tool demonstrating POD documentation and core module usage

### macOS Tools

- **`hello`** - AppleScript greeting with dialog interface and argument parsing
- **`hello-swift`** - Native Cocoa app with GUI form, checkboxes, and real-time greeting updates

### Userscripts

- **`hello.js`** - Animated browser greeting with floating dialog, customizable options, and auto-dismiss