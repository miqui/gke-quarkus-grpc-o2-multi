# Jev: a blind check of the GC choice

This file holds a typed prompt for [Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev), TypeSafe AI's
"System One" model. Jev reads a state and answers questions from a fixed set of options, with a
probability for each option. The prompt asks Jev the question the GC experiments answered: which
garbage collector should `job-manager-api` run on this dev cluster? Comparing its answer with the
measured result shows what a model gets right from general knowledge alone, without any load tests.

This is a cheap prior, not a replacement for the experiments. Jev can only pick from the options
below. It cannot propose experiments or read measurements it was not given.

Nothing here has been run yet. The API shape follows docs.typesafe.ai as of 2026-10-18 (early
access) and has not been tested against the live endpoint.

## Rules for the comparison

- **The state is blind.** It describes the service, the pod and the load as they were before
  experiment 1. It leaves out every measured result (CPU cost, p99, pauses, working set) and the
  existing recommendation. Adding them would make Jev repeat the answer instead of predicting it.
- **The options are the five collectors from experiment 1.** The descriptions are neutral: what
  each collector is, not how it fared here.
- **Freeze the request before you send it.** Do not change the state after seeing an answer and then
  re-ask. Record the first response.

## Request

`POST https://api.typesafe.ai/v1/systemone`, with `Authorization: Bearer $TYPESAFE_API_KEY`.

Three independent questions about the same state:

| Id | Type | Asks | Compared with |
| --- | --- | --- | --- |
| `collector` | choice | Which collector to run in production | Experiments 1 and 6 |
| `gc_material` | noul | Whether the collector choice changes cost much at this load | Experiment 1 pause share |
| `concurrent_pays_off` | noul | Whether a concurrent collector (G1, ZGC, Shenandoah) is worth its CPU here | Experiment 1 frontier |

```bash
curl -sS -X POST https://api.typesafe.ai/v1/systemone \
  -H "Authorization: Bearer $TYPESAFE_API_KEY" \
  -H "Content-Type: application/json" \
  -d @- <<'EOF' | tee jev-response.json
{
  "model": "jev-latest",
  "state": {
    "service": "job-manager-api: a Quarkus 3 gRPC job-queue API (create, list, claim, complete jobs) backed by PostgreSQL, with a Hazelcast cluster cache and a Caffeine local cache",
    "runtime": "JVM fast-jar on eclipse-temurin:21-jre (JDK 21). No GC flag is set. JAVA_TOOL_OPTIONS: -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError",
    "jvm_ergonomics": "The container has 2 active processors and less than 1792 MB of memory, so JDK 21 treats it as a client-class machine and selects SerialGC by default. Max heap is about 576 MB",
    "threading": "gRPC handlers run on virtual threads (@RunOnVirtualThread); parked virtual-thread stacks live on the heap",
    "pod_resources": "CPU request 250m, CPU limit 1500m, memory request and limit 768Mi",
    "cluster": "Short-lived GKE Standard dev cluster on e2-standard-2 nodes (2 vCPU, 8 GB), one service pod per node by anti-affinity",
    "autoscaling": "HPA on CPU only: 70% of the 250m request, 3 to 6 replicas. Extra GC CPU turns into extra replicas and then extra nodes",
    "load": "Moderate steady gRPC load: about 10 lifecycle iterations/s (about 72 requests/s) per pod, sized so the pod uses about 175m CPU. The mix can also be read-heavy (list) or write-heavy (create)",
    "cost_axis": "CPU-seconds per 1k requests (lower is better)",
    "slo": "p99 no worse than 1.10 x the current default configuration's p99, errors under 1%",
    "memory": "A fit constraint, not a cost: no OOM kills, working set under 80% of the limit"
  },
  "questions": {
    "collector": {
      "type": "choice",
      "instructions": "Which garbage collector should this service run in production to meet the SLO at the lowest CPU cost per request?",
      "criteria": {
        "Serial": "-XX:+UseSerialGC. Single-threaded stop-the-world young and old collections (the current implicit default)",
        "Parallel": "-XX:+UseParallelGC. Multi-threaded stop-the-world collections, tuned for throughput",
        "G1": "-XX:+UseG1GC. Region-based, mostly concurrent marking, pause-time goal",
        "ZGC": "-XX:+UseZGC -XX:+ZGenerational. Generational ZGC, concurrent, sub-millisecond pauses",
        "Shenandoah": "-XX:+UseShenandoahGC. Concurrent compaction, low pauses independent of heap size"
      }
    },
    "gc_material": {
      "type": "noul",
      "instructions": "At this heap size and load, does the choice of garbage collector change CPU cost per request by more than 10%?"
    },
    "concurrent_pays_off": {
      "type": "noul",
      "instructions": "Would a concurrent collector (G1, ZGC or Shenandoah) be worth its extra CPU for this service, given the SLO and the cost axis?"
    }
  }
}
EOF
```

The docs are inconsistent about one field. The Quick Start uses `"model": "jev-latest"`, but the
Choice page's example sends `selectedModels`. If the request is rejected, try `selectedModels`.

Each `choice` answer has `choice` (the most likely option), `probabilities` (summing to 1) and
`confidence` (0-1). Each `noul` answer is a single value from 0 to 1.

## What the experiments measured

Do not add this section's content to the state. It is here to grade the answer.

| Question | Measured | Source |
| --- | --- | --- |
| `collector` | **Serial**, the cheapest point on the frontier (2.58 CPU-s per 1k). Parallel is also on the frontier in experiment 1 (about 4% more CPU, p99 within noise). G1, ZGC and Shenandoah are dominated (16 to 25% more CPU). Serial is the only k6-p99 frontier point under the read- and write-heavy loads. | [`experiment-1-collector-shootout.md`](experiments/gc/experiment-1-collector-shootout.md), [`experiment-6-workload-sensitivity.md`](experiments/gc/experiment-6-workload-sensitivity.md) |
| `gc_material` | **Yes across all five collectors** (Serial 2.58 vs ZGC 3.23 is about 25%), **no between Serial and Parallel** (2 to 4%). Serial's own pauses were about 1.5 s in a 560 s window. | Experiment 1 |
| `concurrent_pays_off` | **No.** No latency gain, 16 to 25% more CPU, and ZGC and Shenandoah peaked at about 750 MiB of 768Mi. | Experiment 1 |

Grading `collector`:

- **Match:** `choice` is Serial.
- **Near miss:** `choice` is Parallel. It is on the experiment 1 frontier but costs a little more.
- **Miss:** G1, ZGC or Shenandoah.

Also record the probability Jev gave Serial and Parallel together, and its `confidence`. A
confident wrong answer tells you more than a spread-out one.

## Results

Not run yet. When it is, record here the date, the `model` version from the response, the three
answers with their probabilities and confidence, and the grade.
