# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Onesies is a collection of self-contained, single-file tools designed for portability and simplicity.

### Core Principles

- **Single File Rule**: Every tool must be fully contained in one source file. Each tool may also have a single-file test suite (named `<toolname>-test`) alongside it.
- **Isolation Rule (hard)**: Tools are independent by design. No tool imports, calls, shares code with, or depends on another tool, and **a change to one tool never touches another** — not its source, not its test, not to "fix" or "tidy" it in passing. Work scoped to tool X may change only `cli/X`, `cli/X-test`, its `bench/X/` directory if it has one, and the shared docs (`README.md`, `CLAUDE.md`). Anything else in the diff is a bug in the change, whatever its merits, and gets reverted. Automated agents: this is enforced by the gate (`bench/bigcurl/verdict.sh` refuses an out-of-scope diff); a human reviewer applies the same rule by hand.
- **No Dependencies**: Tools should only rely on standard system programs and commonly available utilities. Exception: `gmail-sync` uses PEP 723 inline metadata with `uv` for Google API packages — this is acceptable when the tool's core purpose requires an external service SDK.
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
3. **web/**: Single-file web applications (HTML with embedded CSS/JS)
4. **userscripts/**: Browser console JavaScript snippets

`bench/` is an accepted exception to the single-file rule: benchmark harnesses
need a server-side provisioner, a network lab and a runner, and splitting them
is what makes them reproducible. Keep each harness in its own subdirectory with
a REPRODUCE.md and the raw CSVs behind any published numbers.

## Development Guidelines

### License Header (Required)

Every program file MUST include this header at the end of the opening comment block (after the description, before code begins):

```
Joe Walnes <joe@walnes.com>, <YEAR>, MIT License
https://github.com/joewalnes/onesies
```

Use the current year. Use the appropriate comment syntax for the language (`#` for shell/perl/python, `//` for Swift/JS, `--` for AppleScript). The order is: shebang, then description, then author/license.

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

### Web Tools
- Single HTML file with embedded CSS and JavaScript
- No external dependencies (no CDN links, no build step)
- Open directly in any modern browser

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

**10. Wrapping Standard Tools as an Engine (`bigcurl`)**
- Wrapping `curl` for transport gets HTTP/2, TLS, redirects, proxies and every auth scheme (basic/digest/NTLM/negotiate via `--anyauth`) for free — write the scheduler, not the protocol
- Pipe each `curl` to **stdout** and have the parent `sysseek`+`syswrite` into a sparse file at the right offset. Beats per-chunk temp files: exact byte accounting with no progress-meter parsing, no final concatenation pass, and stall detection reduces to "this pipe went quiet"
- `close()` on a handle from `open($fh, '-|')` **already reaps the child and sets `$?`**. A follow-up `waitpid()` reaps nothing and sets `$?` to -1, making every transfer look like a failure
- Per-request TCP+TLS handshake dominates on real CDNs. Size each range request as `remaining_blocks / connections` so requests start large and shrink to single blocks at the tail (which is also what stops one slow connection owning the end of the file)
- Reuse the post-redirect URL (`curl -w '%{url_effective}'`) for block requests. Re-following the redirect every time made the tool slower than plain `curl`. Signed CDN URLs expire, so treat a 401/403 mid-download as "re-resolve and retry", not a hard failure
- Probe with HEAD first, but plenty of servers answer HEAD with 405/501 while serving GET fine — only 401/403/404 should be fatal there. Fall back to a `--range 0-0` GET with `--max-filesize`, whose exit 63 doubles as proof the server ignores `Range`
- Guard against a server ignoring `Range` at runtime too: if a worker receives more bytes than its range, abort before it overwrites the rest of the file

**11. Zero-Module Perl**
- Debian's `perl-base` (what you get in slim containers) omits `JSON::PP`, `Errno`, `Getopt::Long` and friends. For maximum portability use *no* non-pragma modules: hand-roll arg parsing and JSON, use 4-arg `select()` with `vec()` instead of `IO::Select`, and `eval { require Time::HiRes }` with a fallback
- `EINTR` is 4 on Linux, macOS and the BSDs — hardcode it rather than pulling in `Errno`
- `/usr/bin/perl` ships in base macOS; `/usr/bin/python3` is a stub that prompts for Command Line Tools. Worth knowing when picking a language for a copy-one-file tool
- A hand-rolled JSON encoder must **not** guess types from the value. Auto-detecting "looks numeric" emitted a block bitmap (`"111000..."`) as a bare number. Pass numbers through an explicit `num()` wrapper (a scalar ref) and treat everything else as a string
- `$1` is clobbered by *any* subsequent match or substitution. In a `while (/.../g)` loop, capture the key into a lexical **before** running an unescaping `s///` on the value

**12. Resumable Downloads**
- Resume state = a completed-block bitmap plus enough identity to prove the remote file has not changed (size, ETag, Last-Modified, block size). Mismatch means restart, not a corrupt file
- Freeze the block size for the life of a `.part` file — changing it invalidates the bitmap. Adapt to fast links by *coalescing adjacent blocks* into bigger requests instead; granularity and request size then vary independently
- Mark blocks complete as their bytes land, not when the request finishes, so an interruption loses at most one block
- Write state atomically (temp file + rename) and save it on interrupt as well as periodically

**13. Testing Network Tools**
- Put a fault-injecting HTTP server in the test file itself (a runtime heredoc keeps it one file). Modes for ranges/no-ranges/405-on-HEAD/401/404/slow/drop-mid-response cover almost every real-world failure
- `( cd dir && tool ) &` gives you the *subshell's* pid, so `kill -INT $!` never reaches the tool. Run the binary directly in the background (use its own `-d` flag instead of `cd`) when a test needs to signal it
- When several workers can finish in the same pass, guard the completion path — otherwise the second one to see a full bitmap tries to rename an already-renamed file
- Benchmark against a server that throttles *per connection*; that is the case parallel chunks exist for. On a link already saturated by one stream, expect parity, and say so rather than claiming a speedup

**14. Benchmarking a Network Tool Honestly**
- Measure against a server that throttles *per connection* and against one that does not. Parallel chunking is worth ~10x on the first and nothing on the second; quoting only one of those is marketing, not measurement
- Verify every timed run (sha256 against a reference copy) — a fast wrong answer must score zero. Delete the output between runs, or a tool that correctly skips an already-complete file posts an absurd time
- Interleave repetitions across tools rather than running all reps of one tool back to back. On a link whose capacity drifts (Starlink), batching charges whichever tool happened to run during the bad minute
- Never let two benchmark suites touch the same box at once. One overlapping run produced numbers that differed 2.3x from the clean re-run, and they looked perfectly plausible
- `tc netem` in a veth/netns pair beats renting boxes in far regions: RTT and loss become exact, reproducible variables instead of whatever the internet was doing. `netem delay X/2` on *both* ends gives a round trip of X
- Watch the fixture size. A 32 MB file at 250 ms RTT is mostly TCP slow start, which flatters single-stream curl and understates every parallel tool; the same comparison at 1 GB reversed the result (curl 12.4 MB/s vs bigcurl 18.9)
- Packet loss, not latency, is what parallel connections actually fix. Per the Mathis relation a single stream gets ~MSS/(RTT*sqrt(p)), so at 0.5% loss one stream collapses while N streams each get their own share — measured 6-16x

**15. Tuning a Parallel Downloader**
- Size each range request as `ceil(blocks_remaining / connections)` using *total* outstanding work. Subtracting in-flight blocks means each successive worker gets a smaller share than the last (4, 3, 3, 2, 2...) because the pool is filled one worker at a time; that cost 40% of achievable throughput at 250 ms RTT
- Big spans amortise connection setup but commit the whole file up front, so a straggler owns the tail while everyone else idles. Pair them with work stealing: an idle connection takes the back half of the busiest worker's span and the donor is killed at the new boundary. Worth +55% under loss
- An adaptive connection count must not react to a single bad sample. Requiring two consecutive degraded windows before shrinking, and only letting an explicit 429/503 shrink immediately, took the auto mode from *worse* than a hard-coded `-n 16` to within 15% of aria2
- Only 4xx is permanent. A 503 from a per-IP connection cap is the server saying "fewer connections please" — treating it as fatal means failing against a server you were merely being too enthusiastic with
- Piping every byte through the parent process buys exact progress accounting and no concatenation pass, and costs about 2 extra copies per byte. Invisible below ~50 MB/s; on a 1-core box at 76 MB/s it cost 44% of throughput. Know which trade you made
- Perl aliases array elements in `foreach`, so a function that rebuilds `@workers` while a loop is iterating it is undefined behaviour ("Use of freed value in iteration"). Iterate a snapshot `@{[ @workers ]}` and mark entries dead rather than splicing mid-loop

**16. Making a Parallel Downloader Actually Win (second tuning pass)**
- Under packet loss, per-connection throughput varies wildly, so **many connections doing small requests beat few connections doing big ones by ~2x**. aria2's edge was entirely its dynamic 1MB pieces: with 4MB pieces it fell to raw-curl speed. 32 curls x 1MB each was the fastest thing measured. On a clean 250ms link 32 parallel slow starts still grow the aggregate window faster than one stream. Result: `CONNS_START=32`, small spans, and `-n 32` won or tied every netem cell
- Scale the opening pool with cores: every connection is a process, and on a 1-core VPS whose network is userspace WireGuard, 32 of them starved the tunnel (29 MB/s vs 51 for four). `4 x ncpu`, capped at 32
- `close()` on an `open('-|')` pipe blocks in `waitpid`. On a contended box that was 37ms per curl exit during which nobody's pipe was read. Make the pipe by hand (`pipe` + `fork` + `open STDOUT '>&'`) and reap with `waitpid($pid, 1)` (WNOHANG == 1 on Linux/macOS/BSD) from the event loop
- Size requests from the *latest* speed sample, not a 2s tuner window - the first two seconds on a fast link otherwise run on the tiny opening spans (27 processes for one 256MB file at `-n 4`). Feed the first completed request's rate straight back in
- Only steal work from a donor with several seconds left (`remaining_bytes / donor_rate > 3s`); stealing from one about to finish just churns connections at the tail
- The block size is the unit the tail is paid in: with 40 slow connections a 1MB block took ~8s, so 20% of a Starlink run was draining. Smaller blocks (256KB under 100MB) shorten the tail; coalescing from measured per-connection rate keeps early requests large. But the *opening* span must not shrink with it - 512KB x 32 opening requests cost 27% at 250ms until the initial coalesce was raised to 4 blocks
- Grow the pool only on two consecutive better windows once past the opening size; one lucky sample on a noisy link added processes a small box could not afford
- Batch HEAD probes with `--next` and `-w '%header{...}'` (curl >= 7.84, detected by the literal `%header{` in output and falling back): 200 small files went from 200 probe processes to 8
- `pgrep -f "<script-name>"` inside an ssh whose own command line contains that same string matches itself and loops forever. Anchor the pattern or count output rows instead
- Measured but not implemented: piping `curl | dd of=file seek=N conv=notrunc` removes perl from the byte path and reaches 71 MB/s on the CPU-starved box vs 51 for the perl loop (curl alone 77). Linux-only, one extra process per worker, and progress would come from `/proc/<pid>/fdinfo`
- `-n` is a ceiling, not a pin. Pinned at 16 against a server capping 8 per IP, the pool retried into 503s until the download failed; letting a 429/503 shrink the pool regardless of `-n` fixed it
- Remember the pool size a 503 shrank you to and never grow past it again. Without that the tuner regrew into the cap and oscillated at half the throughput of simply staying under it
- A per-file "fair share" span cap makes no sense for many small files: it split each 1MB file into four 256KB requests across the pool (808 processes for 200 files, 2x slower than a shell loop). Floor every request at 1MB - which is also the size that won the lossy cells
- `strace -c` timings under heavy process churn are inflated by strace itself; 808 `wait4` calls "at 5ms each" looked like blocking reaps, but `waitpid($pid, 1)` was non-blocking all along. Test the primitive in isolation before rewriting around it
- A 429/503 from a connection cap means "too many at once", not "go away". Put the refused blocks straight back on the queue and shrink the pool *now*, to the number of workers that were streaming when the refusal arrived - exponential backoff left slots idle for seconds, and counting refusals per window (which retries inflate) once pinned the pool at one
- Each 429/503 is one connection over the cap: take exactly one off the pool per refusal, as it arrives, and remember that size as a ceiling. Estimating the cap from "workers streaming at the moment of a refusal" is wrong early in a storm (almost none have bytes yet) and pinned the pool at two
- "Saturated" must allow one worker between requests; requiring every slot busy at the sampling instant meant a churning pool never grew (18 MB/s against a server that gave 32)

**17. Scratch Directory Naming Under the No-Modules Rule**
- A scratch dir named only `"$TMPDIR/tool.$$"` is not unique across runs: PIDs wrap and get reused, and a killed run leaves its directory behind under that PID, so a later invocation reusing the same PID hits `mkdir()`'s `EEXIST` - reproducible in one line by pre-creating that exact path and running the tool against it (no fault injection needed)
- `%!` (each key true iff `$!` matches that errno) is a Perl core special variable, populated by the interpreter itself with no `use Errno` needed - it costs nothing against the zero-non-pragma-modules rule and is the only portable way to distinguish EEXIST from a real disk error without importing anything
- A collision retry must be bounded and must check *which* errno fired: EEXIST retries with added randomness, anything else (EACCES, EROFS, ENOSPC) fails immediately on the first attempt exactly as before. Conflating them turns a rare, loud disk failure into a rare, silent infinite loop - the worse of the two bugs
- To reproduce a same-PID collision deterministically in a portable test: `exec` inside a `sh -c` script replaces the process image without forking, so a plain `$$` there is the exact PID the exec'd program will see as its own - no PID-guessing race, and no reliance on bash 4's `$BASHPID` (absent on macOS's stock bash 3.2)

## Agent operations

- **Verification recipe:** `perl -c cli/bigcurl && ./cli/bigcurl-test` (45
  cases, local fault-injecting server, ~2 min) is the floor. For any change to
  the download path also run the harness: provision with
  `bench/bigcurl/setup-server.sh` (hosts below), then `bench.pl` on the
  relevant scenario, before and after, same fixtures, same reps. A branch
  without before/after numbers does not merge. The verdict file is
  `.verdict` in the worktree root: `perl -c` exit, test-suite exit, HEAD, and
  a timestamp, written by `bench/bigcurl/verdict.sh`.
- **Autonomy:** merge locally into branch `bigcurl` only. Never push. Never
  touch `main`.
- **Shared singletons:** the two benchmark hosts, `root@5.78.179.108`
  (Hetzner, 16 cores, origin + netem lab) and `root@143.198.232.48` (DO,
  1 core, origin + client). Only ONE measurement suite may run against a host
  at a time — a second contaminates both (measured 2.3x error). Take the lease
  `$(git rev-parse --git-common-dir)/leases/bench-hosts` before any remote
  measurement and release it after. Starlink measurements run from this
  desktop and count as using the host they pull from.
- **Do-not-touch:** the single-file rule; the no-modules rule; `main`.
- **Global-blast-radius files:** the configuration block at the top of
  `cli/bigcurl` (every tunable). Changing a default there needs a number.
- **Requests lane:** `ASKS.md`.
- **Fleet defaults:** 3 workers plus the foreman; merge-locally-only.
- **Setup version:** minimal, hand-written for go-team; not `/project-setup`.
- **Do-not-touch (added by the human, 6 Sep):** every other tool in this repo. Tools are isolated by design with no cross-deps; a bigcurl branch may change only `cli/bigcurl`, `cli/bigcurl-test`, `bench/bigcurl/`, `ASKS.md`, `CLAUDE.md`, `README.md` (bigcurl entries only) and `bigcurl-benchmarks.html`. The gate must refuse any branch whose diff against `bigcurl` touches anything else.

## ASK 3 (hedged tail requests) - lessons learned

- **A hedge duplicates a request, and two live responses for "the same"
  bytes are not guaranteed to agree.** curl_cmd() sends no If-Range/ETag
  conditioning on any block request (hedge or ordinary) - a pre-existing,
  architecture-wide property of bigcurl (ETag is only ever compared once,
  at resume time across separate invocations), not something hedging
  introduced. But hedging is the first thing that puts two LIVE streams
  racing for the same offsets at once, so if the origin's answer differs
  between the two requests (a redeploy mid-download, a CDN edge out of
  sync with another), writing both directly as bytes arrive tears a block
  across two different responses - worse than picking the stale or the
  fresh whole block, because it matches no response the origin ever
  actually sent, and it still has a correct length and a complete bitmap.
  Fix: a hedge duplicate buffers its span in memory and commits it in one
  pass only if it wins; the loser's buffer is simply dropped. Proven by
  building a server mode that flips a range's content on its second
  request and checking bytes, not length or a whole-file hash (a
  whole-file hash is the wrong shape here - different BLOCKS legitimately
  landing from different origin generations is the pre-existing, unfixed
  limitation; a torn block is the thing the fix actually closes).
- **A buffer bounded by "it's always small" isn't bounded - it's bounded by
  whatever the user can set the relevant config to.** A hedge duplicate's
  buffer is `span * block_size`, and block size is user-controlled via
  `-B`. "It's just the tail, it's small" was true at the default block
  size and false the moment someone passes `-B 256M`. Needed an explicit
  cap ($HEDGE_MAX_BUF) refusing to hedge past it, not an assumption.
- **A test that asserts the wrong invariant can fail for a completely
  unrelated reason and still look like it caught something.** The
  inherited `$HEDGE_MAX` cap test failed - correctly, by pure luck - but
  its own diagnosis was wrong: it assumed the cap bounds a hedge's
  *lifetime* total, when the code bounds *concurrent* duplicates (pairs
  resolve and free a slot for a later, independent pair, which is
  correct). The actual defect was the fixture: uniformly-paced blocks all
  requested at once all finish within the same instant of each other, so
  there is structurally never a straggler once the tail is short enough to
  hedge - hedging silently never fired at all (measured: 0 duplicates),
  and the test failed on an unrelated byte-count assertion instead of
  reporting that. A fixture with a fast head and a slow, lingering tail
  (server pacing keyed off a per-connection request counter) was needed to
  make a genuine straggler reproducible at all.
- **A live counter shared across forked test-server children needs real
  locking, not read-then-write** - inherited this fix mid-branch from a
  sibling (`counter_next()`, flock-based) and adopted it for a new counter
  of my own rather than re-inventing a second, unlocked mechanism.
- **When measuring, verify the measurement instrument before trusting a
  null result.** A first netem run reported "0 hedge duplicates issued" on
  a scenario later confirmed (via a proper diagnostic build with
  per-branch counters inside `hedge_work()`) to be issuing several - the
  binary being measured had simply never been instrumented to print the
  marker being grepped for. Would have shipped a false "hedging never
  fires under loss" finding. Built the diagnostic *before* trusting any
  timing number from a cell that reported zero duplicates.
- **Bandwidth-constrained real links and loss/RTT-simulated links are not
  the same failure mode, and hedging can respond to them oppositely.**
  Measured: hedging cut the 90%-to-done tail 23-43% under simulated packet
  loss (netem, both loss cells) and under a connection cap layered on top
  of loss, but was slower on Starlink (a link with a real bandwidth
  ceiling rather than isolated per-connection loss) - a duplicate on a
  fresh connection routes around an isolated straggler under netem's loss
  model, but on a shared, bandwidth-capped pipe it just competes with the
  original for the same limited capacity. Name the instrument: a link
  described as "lossy" is not one instrument, and a result from one does
  not transfer to the other.

**10. Measuring Whether a Runtime Signal Exists (regime-signal pass)**
- **Build controls with known impairment before pointing an instrument at reality.** A local origin with selectable models (per-connection rate cap, one global cap split N ways, random per-connection pauses) told us the probe could discriminate at all, and cost zero host time. Without it a null result is indistinguishable from a broken instrument — the exact false negative ASK 3 hit.
- **Retry rate cannot see packet loss.** `retry_per_mb` and `stall_frac` are identically 0.000 at 0.5% netem loss: TCP recovers loss inside the connection, and `emit_retry` fires only on connection failures, stalls and HTTP errors. Do not propose retry rate as a loss detector again.
- **"Helps a lossy link" and "hurts a contended one" are two axes, not one.** Straggler ratio (variance across connections) and parallel speedup (does adding connections add aggregate) are orthogonal — a link can be perfectly parallel with zero straggling. Expecting one scalar to order all regimes is a category error.
- **Starlink is not a shared bottleneck** (measured speedup 4.99 at 8 connections). Its variance is common-mode: uniform across connections at an instant, ±41% over time. Hedging fails there because a duplicate only recovers per-connection bad luck, not because it competes for one pipe.
- **The 1-core droplet is the shared-bottleneck regime** (speedup 1.25) and is cleanly separable from every other cell by a 3x margin.
- **Reproduce before concluding, and let replication kill results.** A straggler threshold separated the regimes by 39% on one pass; on a second pass of the *same cell with the same settings* the clean cell crossed it, leaving 14% — inside the 24% noise floor. Report ambiguous rather than moving the threshold.
- **Pre-register thresholds in a committed file before measuring.** It is the only thing that makes "we did not loosen it" checkable afterwards.
- **Distinguish a candidate signal from a candidate threshold.** Naming `tail_frac` in advance does not make a 0.27 cutoff pre-registered; say which is which.
- **Compare observed extremes, not medians.** Strict non-overlap (lowest lossy rep vs highest non-lossy rep) is the honest test; medians with the spreads dropped hid a threshold crossing here.
- **Normalise a per-connection spread by transfer duration, not bytes.** A 0.5%-loss flow at 250ms RTT moves ~30x less than a clean one; equal spans compare a 25s transfer with a 1s one and score the short one as steadier.
- **Steady-state only for EMA-derived variance.** `progress.speed` starts at zero, and including the ramp read CV 0.87 on an idle loopback origin — larger than any real between-regime difference.
