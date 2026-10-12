# Quiet — native Swift

macOS 14+ application using SwiftUI, AppKit, Swift Charts and Foundation. No webview, Rust backend, JavaScript or privileged helper. Native MLX uses pinned Swift packages (mlx-swift 0.32.3, mlx-swift-lm 3.32.3, swift-transformers 1.3.4); transitive versions are locked in Package.resolved. Use Xcode with Swift 6.2 or newer and the Metal compiler toolchain; the development implementation uses newer APIs behind availability checks. Apple Intelligence requires macOS 26+, with runtime availability checks. Install the Xcode Metal compiler with `xcodebuild -downloadComponent MetalToolchain` if missing. Built with Swift 6 language/concurrency checking; two compiler workers by default.

## Publisher and signing

Publisher: **Mëngøh Labs**. Local builds are ad-hoc signed, without an Apple-issued Team ID. Publisher metadata is self-declared and does not establish Developer ID identity or notarization. Distribution requires your own valid signing identity and separate verification.

The CLI is also a standalone SwiftPM executable and does not need the GUI running. See the [root build instructions](../README.md#standalone-terminal-dashboard) and [terminal guide](QUIET-CLI.md).

## Run

```sh
cd native
swift test -j 2
bash scripts/build-app.sh
open 'dist/Quiet.app'
```

The app stays in the menu bar when its window closes. **Quit & restore scheduling** stops Quiet’s inference server and restores scheduling for Quiet jobs. Existing applications and running batch jobs remain alive. A second native app instance exits without touching the first instance’s recovery journal.

## Bundled terminal companion

The app build includes an ad-hoc-signed `quiet` executable inside `Quiet.app/Contents/MacOS`. It provides a multi-panel mouse/trackpad dashboard with CPU/GPU history, per-core CPU, memory/swap, disk and network counters, a sortable process table, local Apple Intelligence explanations, persistent observations and reviewed isolated-test termination. See [CLI usage and scope](QUIET-CLI.md). The `quiet` SwiftPM product can also be built independently.

## Interface zoom

Use the header’s magnifying-glass buttons or View → Zoom In/Out. Keyboard: **⌘+** (also **⌘=**) / **⌘−**, and **⌘0** for actual size. Click the percentage to reset. Zoom ranges from 75% to 150%, is saved between launches, and scales the full interface. At larger sizes, scroll horizontally/vertically to reach the rest of the layout. Zoom controls stay at the left of the header.

## Native silicon runtimes (0.4)

Acceleration offers four explicitly selected backends. Switching runtime work releases Quiet's previous runtime first; no silent cloud/provider fallback.

| Runtime | Models | Execution evidence |
| --- | --- | --- |
| Apple Intelligence | Apple's on-device SystemLanguageModel | Availability and completed response; Apple does not expose processor placement |
| MLX | Local safetensors + tokenizer folder | Checked MLX GPU backend, active allocations, load/request timings; CPU tokenization still occurs |
| Core ML | Local compiled `.mlmodelc`, fixed-shape numeric tensor inputs | `.cpuAndNeuralEngine` policy (GPU excluded), compiler operation plan when available; plan is not live utilization |
| Ollama | Installed compatible GGUF models | CPU/Metal allocation read back from `/api/ps` |

MLX does **not** use the Neural Engine. Core ML models must be converted and supported separately; an Ollama/MLX model cannot simply be pointed at ANE. Apple Intelligence is a separate model, not an accelerator for Ollama. Performance depends on model, quantization, context and workload; no cross-runtime speed or energy superiority is claimed.

Native text requests are limited to 8,000 input bytes and 128 output tokens. Core ML accepts JSON mapping each input feature to a flat array of finite numbers, validates its shape and displays the first 64 output values. Core ML model handles are released after each request. MLX retains one model for reuse, caps its reusable allocation cache at 64 MiB and releases idle weights after five minutes. Stop/Quiet cancels and drains the active native request before releasing weights. Apple owns the lifetime of its system model; Quiet cannot unload that shared service.

Select a complete local MLX model folder, or use the CLI's explicit model-download commands. Models are not bundled. Downloading and running a model are separate operations with separate license and hardware requirements; see [third-party notices](../THIRD_PARTY_NOTICES.md).

**Explain this snapshot locally** prepares a prompt from CPU/thermal telemetry for review, then you can run it using Apple Intelligence. It does not send process paths, arguments or environment values, and the model has no process-control tools.

## Controls and their limits

- **Observe:** sample readable processes; queued jobs run normally.
- **Balanced:** defer new Quiet jobs under serious/critical/unknown pressure, request background scheduling for Quiet's running direct children, restore after 30 seconds of nominal pressure, and restore a managed foreground process.
- **Quiet:** hold new Quiet jobs, request background scheduling for its running direct children, and stop its inference runtime. Existing apps remain untouched. Background scheduling is not a CPU cap and cannot guarantee lower total CPU or quieter fans.
- **Ollama compatibility:** start an isolated, loopback-only Ollama server. Load/switch/run compatible local GGUF embedding or completion models on CPU or Metal GPU. Read `/api/ps` back to verify zero/nonzero GPU allocation; never infer placement from a dropdown. GPU-assisted is not GPU-only. NPU execution is unavailable through Ollama.
- **Measured auto:** benchmark the exact model digest and input with one warm-up plus three requests per device. Compare warm median request latency; CPU wins only when more than 10% faster. Nominal thermals are required. No energy or fan-noise claim follows from this comparison.

CPU inference uses two threads, a 2,048-token context, and at most 128 completion tokens. New inference is refused under serious/critical/unknown thermal pressure. Stop/Quiet can interrupt the owned runtime during a request. Cloud/remote and unsupported model manifests are excluded; cloud features are disabled in the minimal Ollama server environment. This Ollama path does not download models; the separate model library and benchmark preparation do. Existing server on port 11434 is untouched; the standard local Ollama model store is shared read-only by Quiet’s API operations.

Models expire after five idle minutes. A forced app crash can leave the isolated runtime behind; forced-crash supervision is not implemented. Keep this private loopback endpoint for Quiet's requests: it is unauthenticated, and external requests could invalidate placement/calibration assumptions.

CPU temperature shows the hottest valid M3 CPU sensor in °C, alongside macOS thermal pressure. The read-only AppleSMC reader samples 16 known M3 CPU keys, rejects invalid values, and reports unavailable on unsupported hardware or access failure. These sensor mappings are unofficial and may change with macOS; no privileged helper or fan writes are used.

Sampling happens every three seconds with the main window visible and every six seconds otherwise. Activity and charts are bounded and session-local. The ordinary sampler does not read process arguments or environment values. For sustained hot, user-owned JavaScript runtimes only, the diagnostic inspector reads command text locally at most once per minute, extracts an allowlisted mode (such as `bun test`), and discards the raw text. It also reads working directory and parent PID. No environment is inspected; no raw command line or working directory is persisted or sent to an AI provider. The local observation history retains allowlisted process roles and sustained-load evidence. Inference input/output stay in memory; they are not logged. Scheduling changes are journaled before mutation in `~/Library/Application Support/ai.quandrylabs.quiet/native-recovery.json`, using PID + process start time to reject reused identities.

Batch jobs use literal arguments, a minimal local environment, no stdin, and `/dev/null` output. Configure logs in the workload. Only their direct processes are scheduled; descendants are not claimed as controlled. No arbitrary process pausing, CPU capping, fan overrides, machine power changes, startup agent, or system-wide installation is performed.

## Local observation history (0.6)

The app writes **OTLP JSON LogsData** to `~/Library/Application Support/ai.quandrylabs.quiet/Telemetry/quiet-<UTC-hour>.logs.jsonl`. This is a local structured-log implementation of the [OpenTelemetry file serialization format](https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/), not an OTel SDK, network exporter, collector, or MetricsData pipeline. No added service or inference runs for recording.

The existing monitor supplies a point snapshot at most once per 15 seconds (normally every 15–18 seconds): overall CPU, hottest/mean CPU temperature when available, sensor count, thermal pressure, readable/unreadable process counts, sampling duration, care mode, active job count and runtime busy states. Each snapshot includes the top 12 readable processes (name, PID/start identity, CPU and memory), plus up to eight sustained findings and their allowlisted roles. Per-process CPU uses 100% = one core; overall CPU uses all cores. These are point samples, not 15-second averages, and short spikes may be missed.

App start, care-mode changes, successful enqueue, Ollama requests/results, native inference requests/results and reviewed termination requests/results are recorded separately. Termination distinguishes requested, exited, still-present and failed outcomes. This is not a complete audit of every internal scheduler transition. Arguments, executable/cwd paths, raw exception descriptions, prompts, inference output and environment values are excluded. Names and numeric process identities remain local. No fan-speed, energy or per-process heat measurement is implied.

Hourly files retain the current plus previous 24 UTC hours (at most about 25 hours), with pruning on writes/startup. A 64 MiB cap evicts oldest prior files first; a full current-hour file pauses recording with a visible error until rotation. App-closed files are pruned on next launch; the history reader filters to the requested last 24 hours even before cleanup. Directories/files use 0700/0600. Writes are serialized off the main actor, append immediately to the OS, and tolerate an incomplete final line after a crash; they are not fsynced per record, so power-loss durability is not guaranteed.

**Activity → Local observation history** reports the last successful snapshot or write failure and opens the folder. The existing Activity event list and charts remain session-local. Review persisted records without UI access:

```sh
# Use the newly built binary; an older quiet does not have this command.
native/.build/out/Products/Release/quiet history 1
# Optional explicit directory for an exported/copied history:
native/.build/out/Products/Release/quiet history 24 /path/to/Telemetry
```

The command returns readable JSON with timestamps, flattened fields, and a malformed-line count. Empty records mean no retained observations, not an idle machine. History starts only after reopening the updated app; earlier in-memory observations cannot be recovered. See [verification guidance](../docs/verification.md).

## Diagnostic findings

Overview's **Where to investigate** panel waits for ≥50% of one core for 30 seconds, or ≥20% for 60 seconds. It shows up to eight findings with mean sampled CPU, observed duration, role and working directory when readable, and a concrete next check. It distinguishes test runners, runtime/development candidates, browser work, virtual machines and logging shells without claiming that CPU proves a bug. A test runner older than an hour with parent PID 1 receives a progress-check hint, not an automatic stop.

Evidence is keyed by PID plus start time, resets after exit, low load, PID reuse or a sampling gap over 15 seconds, and retains at most 40 recent points for 256 candidates. Average CPU covers the last 90 seconds, while duration describes the current sustained-load interval. Classification is heuristic; scripts invoked indirectly may remain “JavaScript runtime.” Root-owned processes can be unreadable, and that coverage gap is displayed explicitly. There is no automatic stack profiling, throttling or stopping of unrelated work.

See [diagnostic interpretation](DIAGNOSTICS.md) for coverage limits and next checks.

## Reviewed test termination

Use **Review stop…** in a diagnostic finding or process-table row. Quiet inspects the current PID/start identity, executable, owner, recognized test-runner role, child processes and network sockets. Root/other-user processes, Quiet and its ancestors, system/security/virtualization paths, unrecognized roles, attached children, network activity and failed inspection are blocked. This first release deliberately supports isolated test runners only.

The review expires after 60 seconds and is single-use. **Stop test** rechecks the conditions, sends SIGTERM to that PID only, and observes exit for roughly ten seconds. If it remains present, **Review force-stop…** creates a fresh review; only a second explicit confirmation sends SIGKILL. Force eligibility expires after five minutes. No process groups, descendants or privileged helpers are used. Zombie exits are recognized without reaping another program's child. Results appear in session-local Activity.

These checks cannot establish zero service impact: tests can share files, IPC or external state, and process topology can change between inspection and the signal. Darwin does not expose an atomic start-identity-bound kill handle; the final PID/start/path/UID check immediately precedes the signal but cannot mathematically eliminate PID-reuse races. Graceful stop may interrupt test output/cleanup; force-stop prevents cleanup. There is no autonomous external-process termination policy and no inference model can authorize a stop.

## Artwork

Quiet uses the official Glyph portrait for its icon and sidebar, approved canonical poses for Workloads/Activity and Acceleration, and a Quiet-specific observatory scene generated directly from the canonical references for Overview. The previous chibi artwork is retired and excluded from the bundle. Original proportions and transparent artwork are preserved. See [asset provenance](Resources/ARTWORK.md).

## Benchmark

See [benchmark methodology and limitations](BENCHMARK.md). The optional `scripts/prepare-benchmark-model.py` downloads and SHA-256 verifies a Qwen GGUF into a separate Quiet benchmark store; the default Ollama store remains unchanged. Run the release `quiet benchmark /absolute/path/results.json` after staging compatible local models. This explicitly runs bounded synthetic inference, records outputs, and stops its owned runtimes when complete.

## CLI verification

Get the binary directory with `swift build --show-bin-path` (the active Xcode SwiftPM build system may use `.build/out/Products/Debug`).

```sh
swift run -j 2 quiet hardware
swift run -j 2 quiet verify-apple
swift run -j 2 quiet verify-mlx /path/to/local-mlx-model
swift run -j 2 quiet verify-coreml /tmp/QuietIncrement.mlmodelc
swift run -j 2 quiet sample
swift run -j 2 quiet verify-switching
swift run -j 2 quiet verify-auto
swift run -j 2 quiet verify-stop
```

Hardware and sample commands are read-only. Native live checks perform bounded inference and verify Quiet admission. MLX also verifies in-flight cancellation. `verify-coreml` expects the increment fixture generated by `scripts/coreml-fixture.py` (verification-only coremltools dependency), compiled with `xcrun coremlcompiler compile`. The live checks require installed Ollama and `nomic-embed-text:latest`; they start/stop their own isolated runtime and never download a model. `verify-auto` additionally requires nominal pressure throughout. `verify-switching` checks CPU → GPU → CPU, actual embeddings, cross-device cosine similarity, and runtime shutdown. `verify-stop` checks that overlapping Quiet/Stop requests safely interrupt a pending request and share the same cleanup.

## API references

- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Core ML compute devices](https://developer.apple.com/documentation/coreml/mlcomputedevice)
- [MLX Swift LM 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3)
- [Verification checklist](../docs/verification.md)

Quiet 0.8.2 keeps a neutral app and terminal shell, with Mëngøh Labs colors reserved for data visualization. See [color roles and source](Resources/COLORS.md).
