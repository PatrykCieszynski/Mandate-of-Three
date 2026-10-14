# P0 evidence, 2026-10-14

See [the diagnosis and decision](../../marketplace-auction-soci-p0.md) for cohort
selection, limitations, repeat commands and production versus addon scope.

`samples.csv` contains 6,861 valid first-connection/warmed measurements from 27
runs. Times ending in `_us` are microseconds. `profile` selects the native build;
`run` distinguishes repeated cohorts; `wait_mode` distinguishes frame observation
from completed-signal observation. `rows` is returned SQL rows, `matches` is the
matching predicate cardinality before LIMIT, and `cursor` is fixture continuation.
Missing fields remain empty. A first-connection sample is not an OS-cache purge.
Warmups are validated by the harness but are not stored as percentile samples.

`distributions.csv` summarizes p50/p95/max in milliseconds by build/wait/state/
case/adapter/phase. Repeated matching cohorts can have more than 30 samples;
the report's tables identify individual runs when comparing specific cohorts.
`gate_failures` counts violations of the fixed 2,000 ms budget. Expected baseline
failures remain failures; they are not hidden by increasing a timeout.

`sql_us` measures SQLite stepping. `native_total_us` includes the whole native
worker operation. Preparation, description, native copying, parameter marshaling,
queue wait, finished-to-poll wait and conversion have separate columns. Earlier
instrumentation without `marshal_us` used `queue_us` for the combined submit-to-
worker interval; its aggregated pure queue field is intentionally empty.
Residual timings include uninstrumented calls and script scheduling. Component
medians are not additive.

`plans.json` retains actual EXPLAIN detail and match counts. `provenance.json`
retains raw-run SHA256s, source pins, controlled build settings, DLL/static-library
hashes, runtime SQLite compile options and controlled imported-library selection.
Native SQL is unavailable for opaque published DLLs and installed godot-sqlite.

Standalone CSV files contain one version row, one CSV header and measured timing
rows. The `*-broad-pure.txt` files contain exact SQL, typed named bindings, a blank
separator, then expected ordered offer ID/price pairs. Their data is synthetic.
The standalone model parity boundary is narrower than the full Godot item/cursor
projection parity, as stated in the report.

Probe and invalid `/OD` runs are excluded. A corrected `/Od` experiment was
measured before export. The finalized standalone source additionally returns
exit code 2 on a budget failure; its expected rejection was checked before cleanup.

These files preserve measurements after ephemeral database/build/log cleanup.
They are evidence of this Windows fixture, not production throughput, Linux,
PostgreSQL or D1 acceptance.
