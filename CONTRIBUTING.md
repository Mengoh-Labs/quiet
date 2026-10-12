# Contributing

Read the [README](README.md), [verification guide](docs/verification.md) and [security policy](SECURITY.md).

1. Fork and branch from `main`; keep each change focused.
2. Explain the trigger, current problem and resulting behavior.
3. Set up the test-only Python environment in the [verification guide](docs/verification.md), run `native/scripts/check.sh` on a supported Mac and report actual results.
4. Test process-control and privacy boundaries with owned disposable processes and synthetic logs, never unrelated workloads.
5. Distinguish unit/PTY tests from physical terminal rendering and live model checks. State skipped checks and missing hardware/model prerequisites.
6. Submit a pull request with sanitized reproduction details.

Do not commit credentials, private agent sessions, personal telemetry, model weights, signing material or build products. Dependencies require pinned versions and retained licenses, including embedded C/C++ libraries. Models retain their own licenses.

Code contributions use [MIT](LICENSE); original artwork follows [CC BY 4.0](LICENSE-ASSETS.md). Preserve upstream notices, submit only material you can license, and keep review respectful. Report vulnerabilities privately through SECURITY.md.
