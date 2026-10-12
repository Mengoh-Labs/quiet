# Quiet terminal dashboard

The CLI can be built and run independently using [standalone build instructions](../README.md#standalone-terminal-dashboard). The SwiftUI app also bundles an ad-hoc-signed native `quiet` executable in `Quiet.app/Contents/MacOS/quiet`. The bundle identifier and the Application Support folder are both `ai.quandrylabs.quiet`.

## Start

```sh
quiet                     # dashboard in a terminal; JSON sample if piped
quiet dashboard
quiet sample
quiet hardware
quiet explain             # on-device Apple Intelligence, explicitly requested
quiet history 1           # app observations for the last hour
quiet history 1 --terminal # terminal observations
quiet agents              # running agent sessions as a table; --json for JSON
quiet agents explain 2401 # on-device read of what the agent owning that PID is doing
quiet models              # local MLX models for narration and chat; pull, use, remove
quiet chat                # print the saved chat; quiet chat clear deletes it
quiet --help
```

Invoke the bundled binary directly:

```sh
'/path/to/Quiet.app/Contents/MacOS/quiet'
```

Build with `bash native/scripts/build-app.sh` from the repository root. If you use a shell alias, point it at the absolute executable path and update it when moving the app. For the standalone build, keep the entire `native/dist/quiet-cli` directory together; do not copy only its executable.

## Dashboard

Full-screen CPU/GPU, memory/disks, network and process panels with rounded, shaded shortcut keycaps. CPU and GPU have live Braille ring gauges with centered percentages; unknown readings show `--` and an unfilled track. CPU/GPU and network histories use brighter crests, shaded areas, and subdued grid/baseline marks. Braille plots retain up to 480 recent samples (history starts empty; no fabricated backfill). Per-core busy percentages come from Mach tick deltas. Hottest CPU sensor and macOS thermal pressure stay prominent. Process rows include thread counts, RSS, and CPU measured in percent of **one core**; wide layouts also show users and individual CPU histories. Whole-machine CPU is normalized across all cores.

GPU utilization comes from the accelerator driver's `PerformanceStatistics["Device Utilization %"]`; shared GPU memory is the driver's `In use system memory`, not dedicated VRAM. These are driver-dependent counters, shown as unavailable if missing. NPU utilization, watts, fan RPM and temperatures mapped to individual logical cores are not measured.

Memory and disks now have separate panels on wide screens and switchable views on compact screens. Memory shows active, wired, compressed, inactive, Other, Free pool and swap, with category bars and occupied-memory history when space permits. Occupied RAM is physical RAM minus the kernel free pool, which already includes speculative pages. Other is the nonnegative residual after subtracting active, wired, compressed and inactive from occupied; inconsistent or missing counters display n/a. Inactive is included in occupancy and is not synonymous with file cache. Occupancy is neither Activity Monitor’s Memory Used nor memory pressure. Swap is disk allocation and is never added to RAM. Calculations use raw bytes; independently rounded rows can differ by a last digit. Multiple local volumes show capacity bars and free/total values; the Next control rotates through volumes. APFS sibling capacities are never summed. Disk R/W has separate auto-scaled histories with current rate / graph ceiling labels. It is aggregate exposed IOBlockStorageDriver throughput (including virtual block devices), not per-volume or per-process I/O. Network interface selection includes physical and tunnel interfaces, excluding loopback. Each interface has separate 64-bit byte counters, rates, interface-lifetime totals, session peaks and independently auto-scaled download/upload plots. The scale control toggles shared scales for direct comparison; interfaces are not summed, avoiding tunnel double counting. Counter resets and newly attached devices leave rate gaps rather than spikes. K/M/G are binary byte units; rates are bytes per second. Graph ceilings use the visible history window, while network peaks cover this dashboard session. Very short windows omit plots before omitting current rates.

Sampling defaults to two seconds, adjustable from one to ten. The shell inherits your terminal background, with soft gray text and borders and a slate selected row. Mëngøh Labs colors are reserved for data: stable chart hues, Signal green CPU gauges/history, and Signal emphasis on the selected process history, using 24-bit ANSI. Frames update only changed terminal rows on samples or interaction. The intelligence panel expands only on request; Escape collapses it. At small supported sizes the layout condenses and hides secondary details; 140 × 45 or larger is recommended for the complete view. Glyph artwork remains in the native app; the terminal prioritizes data density.

| Action | Key / mouse |
| --- | --- |
| Select process | Arrow keys, j/k, click/tap row |
| Scroll selection | Wheel, Page Up/Down, Home/End |
| CPU / memory sort | s or Sort button |
| Reverse sort | x or Reverse |
| Network interface | n or click Net title |
| Disk volumes | d or click Next in disk title |
| Memory / disks (compact layout) | m or click RAM / Disks in panel title |
| Network graph scaling | a or click scale footer; independent / shared |
| Sampling interval | + faster / - slower (1–10 seconds) |
| Filter process name / PID | / or Filter; Enter finishes, Esc clears |
| Explain snapshot locally | i or Insight |
| Chat with Glyph | c or Chat |
| Switch system / agent view | g, Tab, or the masthead control |
| Agents first in the process list | t |
| Open the owning agent's stream | o |
| Scroll an expanded answer | [ and ], or the wheel over the panel |
| Summarize app history | h or Log (visible in wider terminals) |
| Review selected process | r, Enter or Review |
| Confirm reviewed stop | y or Confirm stop |
| Cancel review | n / Esc or Cancel |
| Pause terminal sampling | p or Pause |
| Exit | q / Quit / Ctrl-C |

Mouse and trackpad clicks use [xterm SGR mouse reporting](https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf). Support depends on the terminal; keyboard controls are always available. This is not native multitouch/gesture support. Requires an interactive ANSI-compatible terminal, minimum 80 columns × 26 rows; smaller windows disable process actions. Restores alternate screen, cursor, mouse/paste modes and terminal input settings on normal exit, SIGINT, SIGTERM or SIGHUP. Ctrl-Z suspends after restoring settings and resumes the dashboard on SIGCONT. SIGKILL cannot run cleanup; use `reset` if any terminal app is killed abruptly.

Review/confirmation uses the app's same `ProcessTermination` actor: same-user recognized isolated tests only, fresh PID/start/path/UID checks, protected process rules, no children, no network sockets, single-use expiring tickets. SIGTERM comes first; a timeout exposes a new separate force-stop review. AI output cannot authorize signals. Enter, pasted text, double-clicks and keys batched with opening a review cannot confirm it. Processes names, paths, errors and AI output are sanitized before terminal rendering to prevent escape-sequence injection.

## Rendered header

In a graphics-capable terminal at least 100 columns wide and 30 rows tall, the masthead is one rendered card instead of two text rows: Glyph's circular avatar, the name and `@quiet` version, a status line with a coloured dot (green live, amber paused, red while thermal pressure holds inference), the machine line, and pills on the right for the current view, the model answering as Glyph, the number of agents and how many are working, and thermal state. The card is three rows tall, so the toolbar and every panel sit one row lower than in text mode.

The card is a single image that changes only when its content does. The clock and renderer state (`Warp`, `graphics`, `sync`) therefore move to the right end of the footer line: an image on a row that repaints every second would be resent every second. The view switch becomes an `Agents` control at the right end of the toolbar; `g` and `Tab` work as before. Text mode, narrow or short terminals, and a terminal that rejects graphics keep the text masthead unchanged.

### Rendered buttons and the intelligence identity card

In graphics mode every control is a fully rendered button in the header's style: a tinted pill with a coloured outline, a filled key badge, and the label drawn in the same typeface as the header. Colour follows the kind of action (teal for sorting and filtering, green for Glyph, amber for review, violet for pause, red for quit, blue for history and streams). The button's image covers exactly the cells that respond to a click, so hit targets are the same as in text mode and every keyboard shortcut still works. A disabled control (a blocked stop confirmation) is drawn grey and has no hit target. Text mode keeps character keycaps and text labels.

Because a rendered label is not text on the screen, `QUIET_CONTROL_MAP=<file>` makes Quiet write each control's position, key and label to that file; the graphics harness uses it to find and click buttons.

With at least 110 columns the intelligence panel opens with an identity card in the same style as the header: Glyph's avatar and name, the model that produced the text beside it, and a status line with a coloured dot and the time of the last read. Between 100 and 109 columns the bare circular portrait is used as before; process review, narrower terminals and text mode use the full text width.

## Warp graphics

Warp is the first optimized terminal. In an interactive terminal, Quiet queries Kitty graphics support and enables transparent PNG tiles only after an affirmative reply. Detection uses actual capabilities rather than requiring `TERM_PROGRAM`, so launchers that hide the terminal name no longer require an override. The masthead shows `Warp` when that name is available, otherwise `graphics`. Shortcut backgrounds have actual rounded corners, CPU/GPU gauges use smooth arcs, usage bars have rounded tracks and fills, and CPU/GPU/memory/disk/network history plots use antialiased lines and translucent areas. Labels, values, and process rows remain terminal text with the same keyboard and SGR mouse actions.

The approved Glyph portrait appears beside intelligence commentary in graphics-capable terminals at least 101 columns wide. It uses a circular social-avatar crop centered on Glyph’s face, with a subtle outline and transparent corners. Narrow terminals, text mode, missing artwork, and process review keep the full text area. The portrait is loaded from the app bundle once and uses the same cached image lifecycle as other graphics.

Tiles are generated locally with Core Graphics at twice the reported terminal cell resolution. Plots show actual sampled measurements. Unchanged raster data is cached, but any required replacement explicitly deletes the owned image before transmitting its full replacement. Layout changes retire every owned placement before rebuilding. Quiet never deletes other applications’ images. Unknown measurements and gaps remain unknown.

Use `QUIET_RENDERER=text quiet` to select the existing character renderer. `QUIET_RENDERER=warp quiet` explicitly requests the graphics capability check; it does not bypass the check. Automatic graphics are disabled inside tmux/screen (detected by environment variables or the `TERM` prefix) pending separate integration work. No response or a negative response leaves the text dashboard active. No images or queries are sent for piped output.

The masthead reports `checking` during negotiation, `no reply` after three seconds without a response, `rejected` for an unsupported response, or `text` when graphics were not requested. A late affirmative reply still enables graphics. Empty `TMUX`/`STY` variables do not disable detection. Capability replies may include placement metadata in any order.

All dashboard controls share rounded keycaps and bold labels: the toolbar, memory/disk tabs, disk and network selectors, network scaling, intelligence footer actions, and review/cancel actions. Panel controls align to the right of their headers; compact footers use shorter labels. Mouse targets match the displayed control bounds, with no action in the gaps. A blocked review shows a dimmed, inactive confirmation control. Footer positions remain stable when the selected PID changes length.

Graphics update with measurements and user actions. The dashboard no longer interpolates readings or scrolls cached image crops between samples. Synchronized output keeps text and graphics updates together when supported; settled views emit no animation frames.

Quiet independently queries synchronized output (DEC mode 2026). When supported, the header adds `sync`, and text, image updates, placement changes, and resize clears are presented inside one balanced synchronized frame. Encoding is completed before the frame begins, and synchronization is explicitly released on suspend and exit. `QUIET_SYNC=off quiet` disables synchronization for troubleshooting. An absent/unsupported reply retains ordinary output. Repeated cell-size reports no longer trigger a full clear.

Warp can ignore placement IDs. Quiet therefore uses full image deletion (`d=I`) and replacement rather than cached crop placement. Layout movement and text-row repaint are covered by the protocol harness; this does not substitute for testing the installed Warp renderer.

Protocol and pixel rendering are tested with `scripts/check-warp-graphics.py` (pyte/Pillow required). This harness verifies negotiation with the terminal name removed, memory/disk tiles, PNG transport, caching, input safety, image cleanup, resize, and fallback; it does not verify Warp's own compositor. The user confirmed that the preceding pixel renderer worked in Warp with the explicit override. The expanded graphics and motion have been checked through the protocol harness and a composited preview; direct live UI verification remains unavailable because Computer Use denied access to Warp.

For a reproducible host-side rendering benchmark, run from the repository root:

```sh
swiftc -O native/Sources/QuietCore/MengohPalette.swift \
  native/Sources/QuietCore/TerminalInput.swift native/Sources/QuietCore/TerminalMarkdown.swift \
  native/Sources/QuietCore/TerminalCanvas.swift native/Sources/QuietCore/TerminalGraphics.swift \
  native/scripts/benchmark-terminal-renderer.swift -o native/.build/renderer-benchmark
native/.build/renderer-benchmark
native/.build/renderer-benchmark --wide
```

The fixture uses 43 tiles, including seven full histories, and measures preparation of 114 animation frames after new measurements are submitted. It reports encoding time, wire bytes, and traffic from unchanged updates. It excludes sampling, initial measurement uploads, terminal I/O, and Warp compositor/display latency; these measurements are not a claim of observed display frame rate.

## Markdown in the terminal

Panel titles and command labels use inline Markdown styling. Insight, `quiet explain`, agent streams and chat share one block renderer, identical in graphics and text mode:

| Construct | Rendering |
| --- | --- |
| Headings | Level 1 bold and underlined, level 2 bold, levels 3-6 bold italic |
| Lists | Bullets change by depth, numbered items keep their number, task boxes are kept, and wrapped rows hang under the item text |
| Block quotes | A gutter per nesting level, italic |
| Fenced code | Optional language label, full-width dark rows, spacing preserved, long lines wrap by character |
| Tables | Column widths follow content and shrink to fit, cells wrap inside their column, alignment markers are honoured; a table too narrow for columns becomes one labelled value per row |
| Rules | A full-width line |
| Inline | **bold**, *italic*, inline code, strikethrough, underlined link labels |

Source line breaks are kept. HTML and images are not rendered. Source text still follows the ASCII text policy; only the renderer emits bullets, gutters and separators.

The collapsed intelligence panel shows three rows. Expanded (after `i` or `h`), it grows to fit the answer up to 45% of the terminal height; `[` and `]` or the mouse wheel over the panel scroll longer answers, and the border shows the visible range.

`TerminalCanvas.markdownLabel` renders and clips a single-line label; `markdown` lays out into a rectangle from a scroll offset and returns the total row count. `box(..., markdownTitle: true)` opts a title into Markdown. Keep dynamic process names, paths, and other literal data in `text`, or escape them with `TerminalMarkdown.literal` before inserting them into Markdown.

`quiet explain` emits ANSI styling only on a capable terminal, and emits readable plain text when piped, when `TERM=dumb`, or when `NO_COLOR` is set. Styling is generated internally; content cannot inject terminal control codes or clickable OSC links.

## Agents

`g` or `Tab` switches the dashboard between the system view and the agent view. Quiet recognises Claude Code and Codex sessions, and detects the Claude and Codex desktop apps, Ollama, Cursor, Gemini CLI, LM Studio, aider, opencode, Goose, llama.cpp and MLX servers. Helper processes fold under the session that started them, so one row is one agent. A Claude Code run with no session record (a headless run) is still listed as its own session, without a stream.

| Panel | Shows |
| --- | --- |
| Agents | CPU used by agent processes as a share of the whole machine, tokens per minute across all agents, and one line per harness |
| Agent memory | Agent RAM against physical RAM, with a bar per harness comparing harnesses with each other |
| Net | Unchanged and machine-wide |
| Agent sessions | Harness, PID, status, CPU, RAM, tokens per minute, last log activity, working directory and what launched it |

Status is `working` when the log moved in the last 20 seconds or the harness reports it busy, `waiting` when the last entry is a tool call with no result yet, otherwise `idle`. Token counts come from the session log and exclude cache reads. Per-agent GPU and network use are not measured.

| Action | Key / mouse |
| --- | --- |
| Switch system / agent view | g, Tab, or the masthead control |
| Select agent | Arrow keys, j/k, wheel, click a row |
| Open or close the live stream | o, Enter, a second click on the selected row |
| Scroll the stream | Arrow keys, Page Up/Down, Home, wheel; End or f follows again |
| Next session log of the same agent | n (stream open) |
| Narrate the selected agent | i |
| Close stream / cancel inference | Esc |
| Process view: agents first | t |
| Process view: open the owning agent's stream | o |

The stream shows the owner's prompts, the agent's replies, tool calls with their input, tool results, and reasoning where the harness stores it readable (Codex keeps a summary; Claude Code often stores it empty). Tool input and output are shown verbatim in bounded code blocks. It follows the tail until scrolled; while scrolled back the same entries stay in view as new ones arrive. On terminals under 40 rows an open stream replaces the summary panel.

Agent processes carry a `*` in the process view.

**What is read, and what is not kept.** Quiet reads session logs that already exist on disk: `~/.claude/sessions/<pid>.json` and the matching transcript under `~/.claude/projects`, and the `rollout-*.jsonl` files a Codex process holds open. A Codex session in a terminal appends to its log without keeping it open, so Quiet matches it instead: the newest rollout recorded for the process's working directory, written after the process started, and not held open by or already matched to another process. A stream found this way is labelled `matched by directory`; two sessions started in the same directory can be paired with each other's log. It reads the working directory and open-file list of same-user agent processes, and for script-hosted agents only the name of the first argument. It never writes to a session, never signals an agent from this view, and process review is unavailable in agent mode. Every entry is passed through a redaction step when it is parsed, before it reaches the screen or a model: private-key blocks, provider token formats, JWTs, bearer and URL credentials, values after secret-like keys (a quoted value is masked through its closing quote), and long mixed-case alphanumeric runs become `[redacted]`. Redaction is pattern-based and can miss a credential in an unusual format. Stream text is held in a bounded ring in memory (12 entries per background session, 500 for the open one) and is not written to Quiet's observation store.

Narration uses the on-device model with the same holds as ambient commentary (pause, review, serious thermal pressure, `QUIET_AMBIENT=off`). It runs two seconds after a selection settles and at most every 45 seconds while the agent keeps logging; `i` asks immediately. It receives the last request, the agent's recent statements and recent tool activity, all redacted. It is advisory and can be wrong.

`QUIET_AGENT_HOME` points session discovery at another home directory; the test harness uses it.

## Chat

`c` opens a conversation with Glyph in place of the lower panels; the CPU or agent summary stays above it when the terminal is tall enough. Each question is answered from four things gathered at the moment it is sent: the current measurements (the same evidence ambient commentary uses), the agent table, a redacted digest of one agent's recent session, and the conversation so far. The agent in focus is the one selected in the agent view, or the agent that owns the selected process in the system view.

| Action | Key |
| --- | --- |
| Open | c, from either view |
| Send | Enter |
| Cancel a pending answer, or close | Esc |
| Scroll the conversation | Arrow keys, Page Up/Down, Home, End, wheel |
| Quit Quiet | Ctrl-C (q is text while chat is open) |

While chat is open every printable key is text, so nothing typed can sort, filter, review or quit. A paste is inserted as text, up to 2,000 characters, and can never send. Questions are capped at 2,000 characters. Pause, a running process action and serious thermal pressure hold chat the same way they hold `explain`, and the panel says which. Ambient commentary and agent narration wait while chat is open.

Glyph has no tools: it cannot run commands, stop processes, or message agents, and its instructions say so. Answers are advisory; the small on-device model can misread a table, so check a number against the panel before acting on it. A local MLX model (`quiet models`) gets a longer prompt and usually answers better.

**Saved history.** Turns are saved to `~/Library/Application Support/ai.quandrylabs.quiet/Chat` as JSON lines in 1 MiB segments (directory mode 0700, files 0600). The store is capped at 25 MiB; the oldest segments are deleted first. Only the 40 most recent turns are held in memory, and that is what opening chat restores. Every turn, the owner's included, passes through the same redaction as agent streams before it is shown, sent to the model, or written, to mask recognized sensitive patterns. Redaction is best-effort: unrecognized secrets may remain, and the input line itself displays what you type. Notes such as "held while paused" and failed requests are not saved. `quiet chat` prints recent turns; `quiet chat clear` deletes the store. `QUIET_CHAT_DIR` moves it, which the test harness uses.

## Local models

Glyph's agent narration and chat use Apple's on-device model by default. A local MLX model can replace it, loaded in-process; Ollama is not involved.

```sh
quiet models                                              # list, with the active one marked
quiet models pull mlx-community/Qwen2.5-0.5B-Instruct-4bit
quiet models use Qwen2.5-0.5B-Instruct-4bit
quiet models use apple                                    # back to the default
quiet models remove Qwen2.5-0.5B-Instruct-4bit
```

`pull` explicitly downloads model files over the network. Other runtime integrations may use loopback connections, and user-launched workloads retain their own network access. It reads the repository's current revision from the Hugging Face API, pins every request to that commit, and downloads only top-level model files (`.json`, `.safetensors`, `.jinja`, `.txt`, `.model`). Requests start at `huggingface.co` and may be redirected only to Hugging Face hosts (`*.huggingface.co`, `*.hf.co`). Weights are checked against the listed SHA-256 and small files against their Git blob id. Files land in a hidden folder that is renamed into place only when every file verifies, so a failed or interrupted pull leaves nothing usable behind. Private, gated and GGUF repositories are refused, as is anything over 24 GiB or larger than free disk space allows. Models live in `~/Library/Application Support/ai.quandrylabs.quiet/Models`; a folder placed there by hand is listed as a local folder.

A local model gets a larger prompt (20,000 bytes against roughly 5,200 for Apple's model), so narration and chat see more of a session. If the selected model cannot load or run, the request falls back to Apple's model and says so. Weights are released after five idle minutes. Ambient commentary and `quiet explain` always use Apple's model. A local model shares RAM and GPU with the agents being watched; that load is the owner's choice.

## Local intelligence

Apple’s on-device Foundation Models provide ambient commentary after three samples. Recent CPU/GPU, memory, swap, disk, network, thermal, and sustained-process evidence inform a short conversational observation. Meaningful changes can trigger reassessment at most once per 45 seconds; steady conditions are reconsidered after three minutes. An unchanged observation stays in place with its checked timestamp. Failures back off for five minutes. Pause, process review, competing requests, and serious thermal pressure hold automatic work. `QUIET_AMBIENT=off quiet` disables it. `i` and `quiet explain` request an immediate interpretation using the same evidence and prompt. Answers are advisory, have no control tools, and have no remote fallback. Inputs contain bounded process names and measurements, not arguments, environment values, raw logs or file contents. Commentary is not persisted. Escape cancels inference.

## Persistence and coexistence

App records remain in `~/Library/Application Support/ai.quandrylabs.quiet/Telemetry`. Terminal records use its `Terminal` subdirectory, so a dashboard never opens the app's recovery journal or contends with its observation writer. Terminal snapshots are saved every 15–24 seconds depending on sampling interval, plus action results; same roughly-one-day pruning and 64 MiB cap per store. The terminal can run without the GUI app. `h` reads saved app history; absence of records does not imply low load. `Pause` pauses this dashboard's sampling, not workloads or the GUI app. No global mode/queue changes are made from the terminal.

Terminal observations also retain measured per-core CPU and available GPU driver readings in the existing local OTLP/JSON format. New optional telemetry fields preserve decoding of previous snapshots.

Remaining btop gaps include process trees, signal/nice menus, per-process I/O attribution, custom themes and remote hosts. Quiet intentionally retains its reviewed isolated-test termination policy; selecting an arbitrary service does not authorize stopping it. There is no GPU/NPU migration for arbitrary processes or GUI control IPC.

## Verification

`swift test --package-path native -j 2` covers per-core counter wrap/idle intervals, optional telemetry compatibility, graph orientation and missing-data behavior, canvas bounds, terminal sequence fragmentation, mouse events, release suppression, bracketed-paste safety and terminal-output sanitization in addition to the existing telemetry and process-control tests.

`python3 native/scripts/check-chat.py <quiet binary>` drives the chat panel with the real on-device model against a temporary store: keys that are actions elsewhere stay text, a paste cannot send, answers arrive and are saved, a typed credential is masked on disk, and history is restored on the next launch.

`python3 native/scripts/check-agents.py <quiet binary>` builds a disposable sleeper named `claude`, gives it a fixture session in a temporary home, and checks the agent view, badges, stream follow/scroll, redaction on the wire, and terminal restoration at 80x26, 110x34 and 160x50.

`python3 native/scripts/check-terminal.py 'native/dist/Quiet.app/Contents/MacOS/quiet'` exercises a real pseudo-terminal: rendering, mouse/filter/sort, blocked self-review, resizing, pause/quit, SIGINT restoration, and graceful/force-stop flows restricted to test processes the script creates. It never selects external services for termination. See [verification guidance](../docs/verification.md); a described harness is not evidence that it passed on the current checkout.
