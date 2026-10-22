# W0 current-runtime limits and control baseline

2026-10-21, Windows 10 19045, Ryzen 5 5600X (6 cores / 12 logical CPUs).
Measured commit **30afa656b274d370b2063d23fa45441ab2901ff8**, clean tree in
both reports. Production baseline is `main` **8a934785**, after PR #88.
Changes on the measurement commit are optional test fixtures and documentation;
no production runtime behavior or resource limit changed.

Engine: Godot **4.7.2.stable.official.ed1daf0bf**, debug/editor executable,
headless; actual `Godot_v4.7.2-stable_win64.exe`, not the console wrapper.
Executable SHA256: `ab1824f85bfd8e0e4128182c000c4003a3e042245b2967848d089b2a04b22424`.
Tracked source/test fingerprint:
`9baacc4d1dcf97ff2ceccee18d73abaa8cc4419386979f152a24d17059a18c5f`.
Ordinary developer desktop, not a reserved benchmark host. Local development
processes were not stopped. No other verification workloads ran concurrently.

## Commands and raw evidence

```powershell
git diff --check
& ./tests/run-smoke.ps1 -NodeExecutable C:/Users/Patry/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe
& ./tests/run-spike3d.ps1
& ./tests/run-first-region.ps1
python tests/run-world-capacity.py
python tests/run-world-capacity.py --cohort bindings
```

All PASS. Smoke includes 88 Web UI contracts. Network check uses server + two
clients and verifies speed/collision/disconnect behavior. First Region is a
headless production-content/navigation check, not physical input or visual parity.
No native window, real user database, existing server restart or config change.

Raw unmodified logs/reports remain ignored:

- `.godot/verification/world-capacity/20261021-130824/results.json`: 18 movement runs.
- `.godot/verification/world-capacity/20261021-131657/results.json`: 3 binding runs,
  12 cases each (36 observations).
- `.godot/verification/w0-smoke.log`, normal spike3d/first-region runner logs.

All runs returned one valid result and matched requested actor counts. The
runner rejects script/assertion failures and missing samples. Existing teardown
warnings about 4 ObjectDB instances / 3 resources remain; no claim of leak-free
process shutdown is made. Native processes exited and were reaped normally.

## Synthetic movement results

**Median of three per-run values**, not pooled percentiles. Work is the span
between early/late physics callbacks, not the complete native server tick.
Actual clients, SQL operations and bytes sent are zero. See the
[frozen measurement contract](../../development/world-baseline.md).

| Layout | Players / mobs | Callback work p95 ms | Tick interval p99 ms | Observed Hz | Callback samples >16.667 ms |
|---|---:|---:|---:|---:|---:|
| Dense 32 m | 0 / 0 | 0.070 | 16.730 | 60.00 | 0% |
| Dense 32 m | 100 / 200 | 22.839 | 29.071 | 55.49 | 42.58% |
| Dense 32 m | 250 / 500 | 40.917 | 46.764 | 24.97 | 100% |
| Wide 512 m | 0 / 0 | 0.055 | 16.684 | 60.00 | 0% |
| Wide 512 m | 100 / 200 | 13.676 | 16.688 | 60.00 | 0.28% |
| Wide 512 m | 250 / 500 | 37.187 | 45.849 | 27.87 | 100% |

Dense 100/200 p95 spread: **18.549–24.653 ms**; wide 100/200:
**13.515–14.730 ms**. Dense 250/500: **40.624–40.927 ms**; wide:
**36.189–37.516 ms**. Preserve repeat spread in later comparisons.

Requested observation timer is 12 engine seconds. Actual monotonic windows were
12.27–13.70 s (dense 100/200), 28.70–29.16 s (dense 250/500), and
25.54–26.55 s (wide 250/500). Hz uses those actual windows. These results are
not directly comparable to old experiment numbers: current fixture and code,
chase/leash, cadence and timer behavior must stay identical for a future A/B.

Player roster Variant sizes: 8 / 4,008 / 10,008 bytes for 0 / 100 / 250 players.
Mob Variant sizes: 8 / 19,208 / 48,008 bytes for 0 / 200 / 500 mobs. One roster
encoding is included at production cadence; per-viewer RPC fan-out is absent.
Mob size is sampled at the end, not encoded per viewer on every tick.

## Memory / CPU scope

| Layout | Actors | Median whole-process peak RSS MiB | Median static allocator at measurement MiB | Median whole-process CPU seconds |
|---|---:|---:|---:|---:|
| Dense | 0 / 0 | 217.50 | 107.20 | 3.25 |
| Dense | 100 / 200 | 226.04 | 115.18 | 20.02 |
| Dense | 250 / 500 | 260.00 | 129.01 | 40.28 |
| Wide | 0 / 0 | 1,059.30 | 106.73 | 11.33 |
| Wide | 100 / 200 | 1,058.98 | 115.16 | 23.61 |
| Wide | 250 / 500 | 1,059.68 | 129.04 | 43.81 |

CPU and peak RSS are sampled every 100 ms over startup/warmup/measurement/exit,
not only the measurement window. Wide has a large transient peak **even with
zero actors**. The fixture invokes the production navigation bake on a 512 m
floor before measuring. This is a likely contributor based on the code path;
no isolated bake ablation was run, so it is not a measured attribution.
Do not call the ~842 MiB dense/wide peak difference per-player retained memory.
Runtime static allocator observations are much closer across the two layouts.

## Mock ready binding/cache probe

Actual attach/fingerprint/idle-poll/copy/clean-detach methods, seeded ready
Inventory/Wallet dictionaries, **no SQL, native workers or pending completions**.
Snapshots contain one-cell ore stacks, without rich affix/socket payloads; they
are a defined cache-cost cohort, not the most expensive possible Inventory.

| Requested / admitted | Items each | Median poll us (all accounts) | Median copy us (one peer) | Retained allocator delta MiB | One serialized snapshot bytes |
|---|---:|---:|---:|---:|---:|
| 24 / 24 | 0 | 71.43 | 5.28 | 0.33 | 272 |
| 24 / 24 | 12 | 71.69 | 27.89 | 0.83 | 6,224 |
| 24 / 24 | 180 | 72.39 | 459.10 | 7.79 | 89,552 |
| 64 / 64 | 0 | 192.09 | 7.95 | 0.87 | 272 |
| 64 / 64 | 12 | 205.62 | 31.82 | 2.20 | 6,224 |
| 64 / 64 | 180 | 194.55 | 516.10 | 20.78 | 89,552 |
| 65 / 64 | 180 | 192.88 | 521.07 | 20.79 | 89,552 |

Both owners refuse account 65; every clean-detach case releases both owner maps.
Memory delta includes fixture PlayerResources/session maps, not just the binding.
Polling scales with account count; deep copies additionally scale with payload.
No evidence here establishes >64 live bindings, native recovery cost or safe
login bursts. The static dirty/paused ownership audit and existing native PG
failure suites remain essential. Do not discard retained unknown work.

## Decisions / next review

- W0 reproduces budget overruns without changing controller behavior. W1 should
  attribute player simulation/shape calls, mob AI/motion, serialization, polling
  and startup bake costs before choosing a candidate. No optimization accepted.
- [Limit audit](../../plans/world-w0-limit-audit.md): configured World 200 is not
  enforced as a process budget; Master, Inventory and Wallet have separate caps
  of 64; instance capacity is another dimension. Next settings work must provide
  coherent reservation/refusal and detached-state headroom, not merely move
  constants into a file or raise them to 500.
- Default values, economy atomicity/receipts, worker model, server authority and
  existing gameplay tests are preserved. SQLite remains reference-only here.
- Real 100–500-client networking, native CEF/input, Linux, full combat damage,
  Terrain3D movement parity, high-affix caches, dirty/unknown binding throughput,
  new integrated MMO soak and instrumentation overhead are NOT VERIFIED by W0.
  Those stay in their respective W1/W3/W6 or existing Economy acceptance cohorts.
- Configuration implementation and later W-packages require separate review.
  No automatic merge, rollout, new World host or capacity promise.
