# W1 — current-code World profiling

Opt-in extension of the [W0 baseline](world-baseline.md), not a controller change.
Production source, physics, AI, snapshots, session limits, workers and Economy
transactions are unchanged. No experimental movement implementation is imported.

```powershell
# Dense and wide, 0/0 + 100/200 + 250/500, three interleaved pairs per case:
python tests/run-world-capacity.py --profile compare
# Small setup/coverage diagnostic (not acceptance evidence):
python tests/run-world-capacity.py --profile compare --scenarios 2:4 --layout dense --repeats 1 --warmup 1 --seconds 3
# Separate synthetic displacement diagnostic; not real combat or gameplay parity:
python tests/run-world-capacity.py --profile compare --displacement --scenarios 2:4 --layout dense --repeats 3 --warmup 1 --seconds 5
# Existing ready caches, with separate Inventory/Wallet polling and lookup costs:
python tests/run-world-capacity.py --cohort bindings
```

Use the actual Godot 4.7.2 `win64.exe`, not the console wrapper. Do not run CPU
baselines alongside other tests, live World workloads or builds. Requested
durations, seed, arena, warmup and overload interpretation remain W0's contract.
Large runs remain outside CI. There are no TPS/percentile performance assertions.

## Test-only instrumentation boundary

`tests/support/world_profile_source.py` extracts current production methods into
ignored subclasses beside each run's logs. It inserts timers at exact anchors
and fails before launch if a method/anchor is missing or ambiguous. It never
edits the originals. Generated scripts and hashes are retained with results for
inspection, preventing a separately maintained copy of old movement/AI logic.
Generated-source hashes cover UTF-8 text with LF-normalized newlines; Windows
files may have CRLF. Engine/source-tree fingerprints cover their actual bytes.
The factory changes only which test subclass is allocated. Tests run production
setup, collision policy and native `move_and_slide()`/`intersect_shape()`.

`--profile off` (default) uses original classes. `on` enables subtimers; `compare`
interleaves control/profile, reversing their order every second repeat. Both
variants use the same committed sources, process/physics probes, roster encoding
proxy and seed. Compare reports retain each variant separately, including the
percentage difference in median physics p95. That is measured instrumentation
overhead plus scheduling/workload variation, not a performance improvement.
Quantify it before attributing small buckets or comparing historical W0 numbers.

## Nested timing interpretation

Schema v2 preserves previous observations and adds `profiled`, `displacement`,
`frame_interval`, `profile`, generated-source hashes and an instrumentation
comparison. `median_simulation` keys now include `-control`/`-profile`; v1 report
consumers must adapt. No new public game protocol is involved.

Each bucket aggregates elapsed microseconds over all actors **per physics tick**;
percentiles describe aggregate sampled ticks, not individual actors. Call counts
are retained. Snapshot buckets sample only ticks that actually build snapshots.
Zero-player/mob cohorts legitimately omit actor buckets. Runner checks expected
coverage, actor counts and script errors, never environment-specific speed.

| Bucket | Contains / nesting |
|---|---|
| `world_movement_snapshot` | World callback: input eligibility, all player simulation and player snapshots |
| `player_simulate` | Complete player motion, including the following player buckets |
| `player_slide` | Native `move_and_slide()` |
| `player_intersect_shape` | Native overlap query; query construction and hit filtering remain in the enclosing player total |
| `player_exception_add/remove` | Exception-list read, additions, removals and their iteration |
| `player_advance_curve`, `player_knockback_damping` | Curve integration and knockback decay; baseline usually exercises their inactive paths |
| `player_advance_probe` | Conditional advance collision probe and contact policy; not just native `test_move()` |
| `mob_tick` | All pack/mob lifecycle work, includes AI and motion |
| `mob_ai_inclusive` | Per-mob decision path, including `mob_motion` |
| `mob_motion` | Motion including native `mob_slide`; subtract from AI **means** only as an approximate residual |
| `snapshot_roster`, `snapshot_encode_proxy` | Roster construction and one Variant encoding; no per-viewer transport/fan-out |

These totals overlap. Do not sum parent and child buckets, subtract unrelated
p95s, or call all remaining time native physics. Collection/clock overhead is
inside enclosing spans. Physics-work span and tick/process intervals describe
callback scheduling, not a complete native physics step, GC attribution or OS
wait breakdown. Frame samples may include multiple catch-up physics ticks.

`--displacement` alternates explicit advance and knockback every two simulation
seconds. This separate synthetic cohort exercises active displacement branches
without damage, server attacks or receipts; it cannot establish combat parity.
Ready-binding probes add separate batch polling costs and context lookup timings.
Snapshot-copy cost includes its own peer lookup and dictionary deep copy; the
context probe is a different call and must not be subtracted as an exact split.
Neither probe measures native SQL loading, paused recovery or login bursts.

## Review and rollback

Executed results and limitations: [W1 evidence](../evidence/world-w1-profile/README.md).

Report median-of-three dense/wide rankings with their control overhead and raw
artifact path. CPU/RSS measurements still cover the whole process lifetime.
Keep cache, synthetic motion, real combat and real connected clients distinct.
There is no capacity claim or automatic W2 approval. Remove the optional test
instrumentation to roll back; no runtime migration or service restart is needed.
