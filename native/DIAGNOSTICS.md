# Interpreting diagnostics

Quiet highlights sustained activity as a starting point for investigation. CPU use alone does not prove a bug, stalled test, memory leak or unnecessary service. A long-running process with parent PID 1 can be legitimate.

Per-process CPU uses 100% for one core; overall CPU is normalized across all cores. Samples from different intervals must not be summed as complete attribution. Unreadable processes and missing driver counters create coverage gaps. Temperature is a machine/sensor observation, not per-process heat or power consumption.

Before acting, identify the current process, owner, start time and intended workload. Check application progress and logs using tools appropriate to that application. Do not infer that a security or system service is redundant from its CPU use.

Quiet's reviewed-stop path is restricted to recognized isolated test processes and explicit human confirmation. It does not authorize stopping arbitrary high-CPU services. See [control limits](README.md#reviewed-test-termination).

Diagnostic exports can reveal process names and machine details. Redaction does not guarantee that every private value is removed. Inspect material before sharing it.
