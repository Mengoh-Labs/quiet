<div align="center">

# Quiet

**See what your Mac is doing. Decide what happens next.**

A native system observatory and standalone terminal dashboard, with local AI commentary from Glyph.

[Terminal guide](native/QUIET-CLI.md) · [Native app](native/README.md) · [Verification](docs/verification.md) · [Security](SECURITY.md)
</div>

Quiet combines CPU, memory, disk, network and process observations with an optional view of local coding agents. Use the SwiftUI app, the `quiet` terminal dashboard, or both. They share native Swift code; the CLI does not require the GUI to be running.

**Experimental macOS software.** The package declares macOS 14+, with Swift tools 6.2. Use Xcode with its Metal compiler toolchain. Apple Intelligence requires supported hardware and macOS 26+; other model backends have their own requirements. Not every metric is available on every Mac, and no fan-noise or energy-saving guarantee is made.

## Standalone terminal dashboard

```sh
git clone https://github.com/mmingo-director-of-ai/quiet.git
cd quiet
bash native/scripts/build-cli.sh
native/dist/quiet-cli/quiet dashboard
```

The standalone distribution is `native/dist/quiet-cli/`. Keep the entire directory together: it contains the executable, runtime resources, Metal library and licenses. Run its executable directly or add a shell alias to its absolute path; copying only the executable is unsupported. See the [terminal guide](native/QUIET-CLI.md) for packaging and graphics behavior.

```sh
quiet sample          # a point-in-time JSON sample
quiet hardware        # available hardware information
quiet agents          # detected local coding-agent sessions
quiet explain         # explicitly request a local interpretation
quiet --help
```

The full dashboard needs an interactive ANSI terminal, at least 80 columns × 26 rows; 140 × 45 is more comfortable. Graphics depend on terminal support, with a text fallback. Keyboard controls remain available.

## Native Mac app

```sh
swift test --package-path native -j 2
bash native/scripts/build-app.sh
open native/dist/Quiet.app
```

The app also bundles `quiet` at `Quiet.app/Contents/MacOS/quiet`. Local builds are development artifacts; ad-hoc signing is not Developer ID signing or notarization. See [native setup](native/README.md) for inference backends, workloads and scheduling controls.

## What it shows

- CPU and available GPU counters, memory accounting, swap, disk throughput and per-interface network activity.
- A sortable process table and sustained-load findings, with unavailable readings identified.
- Local coding-agent detection, bounded session-log views and advisory summaries.
- Optional Apple Intelligence or local model interpretation; no model may authorize process termination.
- Local observation history and optional persistent chat, with bounded stores and redaction.

Quiet can review termination of recognized, same-user, isolated test processes. It rechecks eligibility, requires explicit confirmation, tries SIGTERM first and requires a separate review for force-stop. These checks reduce risk; they cannot establish zero impact on shared files, IPC or external state. Scheduling controls apply to Quiet-managed direct child jobs, not all processes on the machine.

## Privacy and limits

Processing uses local telemetry, local agent logs and selected local models. Agent sessions and chat can contain sensitive material. **Redaction is best-effort, not a guarantee that every secret is removed.** Inspect diagnostics and exports before sharing.

Model downloads contact external hosts. Optional Ollama runs through a locally managed loopback service; workloads you launch can make their own network requests. On-device inference does not make the whole process environment offline. Keep model licenses and review downloaded code/data before use.

Quiet is not a privileged system manager. Missing process or driver access limits coverage. It does not measure per-process heat, fan RPM, NPU utilization or watts, and background scheduling is not a CPU cap. Agent classification and model answers can be wrong. Read [security boundaries](SECURITY.md) and the detailed guides before using control features.

## Contribute and license

Start with [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities [privately](SECURITY.md). Automated tests, native compilation and actual terminal/device checks are separate forms of evidence; the public source release does not claim all acceptance checks have passed.

Original code is [MIT](LICENSE). Original Glyph artwork is [CC BY 4.0 with attribution to Mëngøh Labs](LICENSE-ASSETS.md), allowing reuse and adaptation; trademark rights remain separate. Dependencies and model boundaries are described in [third-party notices](THIRD_PARTY_NOTICES.md).
