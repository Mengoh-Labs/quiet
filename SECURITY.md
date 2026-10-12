# Security policy

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/mmingo-director-of-ai/quiet/security/advisories/new). Include the affected commit, prerequisites, impact and a minimal reproduction using synthetic data. Do not post secrets, private agent sessions, process arguments or personal diagnostics in public issues.

The maintained branch is `main`. There are no supported historical release lines or response-time guarantees yet. This experimental software has not received an independent security audit.

## Process controls

Quiet has no privileged helper. Scheduling controls target its managed direct child jobs. Reviewed termination is limited to eligible same-user isolated tests, with explicit confirmation and fresh identity/eligibility checks. SIGTERM and force-stop require separate reviews. Model text cannot authorize signals.

Inspection and signaling are not atomic. PID reuse and process-topology changes cannot be eliminated mathematically, and an isolated-looking test can still affect shared files or external state. Never treat a review as proof of zero service impact.

## Local data and models

Quiet reads native process telemetry and selected local agent logs. Names, session contents and saved chat may contain sensitive data. Redaction is best-effort and cannot recognize every secret. Restricted file permissions and bounded retention do not protect against a compromised account or intentional exports.

Local telemetry has no network collector. Explicit model downloads use external hosting; optional inference runtime communication uses loopback. User-launched workloads and separately installed tools have their own network behavior. Review model licenses and provenance. Local inference is not an assurance that all activity on the machine is offline.

Diagnostics, graphics/control maps and test outputs can reveal machine state. Inspect them before sharing. See [terminal data behavior](native/QUIET-CLI.md) and [native observation storage](native/README.md#local-observation-history-06).

## Contributions and automation

Submit changes through forks and reviewed pull requests. Branch protections and private reporting require GitHub settings; repository files alone do not enforce them. Review workflow, dependency and permission changes carefully. Never expose signing credentials or repository secrets to untrusted pull-request code. Keep private logs, models and local app state out of source control.
