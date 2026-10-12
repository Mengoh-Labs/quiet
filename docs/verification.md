# Verification

The application and standalone CLI share `native/Package.swift`.

```sh
python3 -m venv native/.build/check-venv
native/.build/check-venv/bin/python -m pip install -r native/scripts/requirements-checks.txt
QUIET_TEST_PYTHON="$PWD/native/.build/check-venv/bin/python" bash native/scripts/check.sh
```

Python, pyte and wcwidth are test-only dependencies; the app and CLI do not need Python to run. The gate builds/tests both app and standalone CLI and runs synthetic terminal checks; it does not run live model checks. The terminal harness uses a real pseudo-terminal and owned disposable test processes. Read it before running; it exercises reviewed process termination and terminal-state restoration. It does not certify physical rendering in every terminal.

Record the commit, OS, Xcode/toolchain, terminal, model availability and exact results. A skipped model check is not a successful inference test. Build/signature validation does not establish notarization or runtime permission behavior.

Separately check keyboard/mouse interaction, small windows, resizing, suspension/resume, terminal graphics fallback, unreadable processes, PID reuse and stale review rejection, permission failures, agent-log redaction and saved-data deletion. Confirm that no unrelated process is selected for termination.

Live inference checks and benchmarks are opt-in; they need compatible local models and may start owned runtimes. See [native runtime checks](../native/README.md#cli-verification) and [benchmark methodology](../native/BENCHMARK.md). Hardware counters, physical terminal presentation and model quality require direct observation.

Private development measurements and historical benchmark artifacts are not included in this source release. No earlier test count or installation result is presented as verification of this checkout.
