# Local runtime benchmarks

Benchmarks run bounded synthetic inference using compatible installed models. They are optional, can consume substantial resources, and are not a claim that one backend is universally faster or more energy-efficient.

```sh
cd native
# Explicit download into a separate benchmark model store:
python3 scripts/prepare-benchmark-model.py
swift build -c release --product quiet -j 2
"$(swift build -c release --show-bin-path)/quiet" benchmark "$PWD/benchmark.json"
```

Read the preparation script and model license before downloading. Configure the compatible MLX model and Ollama prerequisites described by the runtime before running. Model weights are not bundled or relicensed by Quiet.

Record hardware, OS, toolchain, runtime versions, exact model revisions, quantization, context, prompts, output limits and background load. Warm-up policy, request ordering, caching and output length affect results. Distinguish end-to-end latency from kernel time and tokens per second.

Check output correctness as well as speed. A model that finishes quickly can still answer incorrectly. Apple shared-service CPU/memory attribution is not directly comparable with an owned process. Summed RSS is not physical footprint or peak memory; shared pages can be counted twice.

CPU time and sensor snapshots do not measure watts, fan noise or per-process heat. Small contended runs cannot establish energy savings or general performance superiority. Keep generated artifacts out of source control unless deliberately sanitized and documented.

Earlier private measurements are excluded from this source release. Reproduce and report results for the actual checkout rather than citing missing historical artifacts.
