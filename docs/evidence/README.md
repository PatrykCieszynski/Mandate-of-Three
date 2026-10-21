# Evidence — measurements and reproducible validation

**Evidence is historical by definition.** It supports a dated result on a particular SHA, build and machine; it is not the active implementation specification.

## Milestone evidence (preferred entry points)
- [Full-state PostgreSQL cutover](postgres-full-cutover/README.md).
- [P4 Representative Economy Soak](representative-economy/README.md).
- [P4c recovery and sustained runs](postgres-p4c/README.md).
- [World W0 baseline](world-w0-baseline/README.md), [W1 profiling](world-w1-profile/README.md).
- [Runtime capacity and ACK admission](runtime-capacity/README.md).
- [Realm workload](realm-workload-foundation/README.md).

## Archived granular evidence
The existing `postgres-p1a` … `postgres-p3v` and other package directories are retained as **historical technical evidence**, not as separate actionable project milestones. Do not read all of them by default. Follow one only to investigate a concrete invariant, regression or original measurement.

## Policy
A PR description holds routine verification and an exact link to CI. Do **not** create a new `docs/evidence/<PR-or-commit>/README.md` per PR or commit. Add one short consolidated evidence report **after a completed milestone** only when it has meaningful reproducible results, failure analysis or a decision worth preserving. Retain raw artifacts in ignored locations unless they are small, intentional fixtures. Always record SHA, environment, commands, limitations and the distinction between synthetic and connected-client tests.
