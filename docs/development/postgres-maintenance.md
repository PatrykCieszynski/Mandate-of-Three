# PostgreSQL operator maintenance barrier — P3t

P3t adds authenticated diagnostics and an acknowledged, process-local stop
barrier for the opt-in single-World PG realm. It does not implement backup/restore,
a distributed maintenance lease, a backend switch or production cutover.
SQLite remains the default and retains its existing deployment workflow.

## Operator API

Use the existing Master dashboard listener/config. Both new routes require a
**nonempty configured dashboard token**, including on loopback. The legacy
auth-disabled development dashboard does not authorize these routes. The current
HTTP addon passes the token in the JSON body; do not put it into URLs/logs. Keep
the listener on loopback or behind the existing trusted/TLS operator boundary.

| POST route | Body | Result |
| --- | --- | --- |
| `/v1/economy/status` | `token` | Sanitized RAM-only Master/World state and current maintenance operation |
| `/v1/economy/quiesce` | `token`, `operation_id` | Start the barrier, or retrieve the same operation's current result |

`operation_id` is 32 lowercase hexadecimal characters. Generate it once and reuse
it after an HTTP timeout; a different ID is refused while an operation exists.
This is bounded process-local operator correlation, not a durable economic receipt.

```powershell
$operatorId = [guid]::NewGuid().ToString('N')
$operatorBody = @{ token=$env:MANDATE_DASHBOARD_TOKEN; operation_id=$operatorId } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/v1/economy/quiesce -ContentType application/json -Body $operatorBody
$statusBody = @{ token=$env:MANDATE_DASHBOARD_TOKEN } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/v1/economy/status -ContentType application/json -Body $statusBody
```

An initial `ok: true` acknowledges the **operator request**, not a completed
checkpoint. Poll status and require `maintenance.phase == "QUIESCED"` and
`maintenance.quiesced == true`. `BLOCKED` is never success. Retrying the same ID
returns its recorded phase without another drain, including after completion.

## Ordering and guarantee

1. Master closes Gateway identity/entry admissions and removes public World
   availability before requesting World drain. Pending entry attempts are fenced;
   a late grant continuation cannot deliver a new ticket. New Worlds are refused.
2. World stops new inventory/authentication, drains existing economic owners and
   resolves captured pending income/uncertain results through their existing
   recovery boundary. Master keeps its grant owner alive during this phase.
3. Only after successful economic drain does World disconnect players. SQLite
   remains open until their disconnect callbacks finish profile saves. World
   verifies writes of the captured latest profiles (the legacy serializer now
   returns the SQL outcome), checkpoints progression and closes SQLite, then acknowledges
   `profiles_closed` and `workers_stopped` over reliable internal RPC.
4. Master accepts only the current operation ID from its recorded World peer.
   Missing, false or malformed proof flags fail closed. It then revokes remaining
   grants, drains its control worker and verifies the account collection save.
5. Successful account checkpoint freezes subsequent normal account-file saves,
   including tree exit. `QUIESCED` is published only after these barriers pass.

Legacy dashboard mutations, password reset and World admin RPCs cannot mutate
closed stores after maintenance starts. Suspended save/restart continuations
recheck closure before touching profiles. An already-running shutdown is refused
as a maintenance proof rather than raced. A PG Master's window close refuses to
stop ahead of connected Worlds without the completed barrier.

Both processes stay alive for status/inspection after success; there is no auto
resume. Stop supervised World before Master after observing `QUIESCED`. Starting
a new process is a separate lifecycle, not a continuation of the old operation ID.
This endpoint does not stop arbitrary processes or verify all possible external
writers. Do not use its JSON as an enduring backup certificate. A coherent backup
still requires stopping the supervised writers and capturing PG, its profile
file/ID and the Master account collection together. That bundle/restore tooling
and acceptance are the next operational package.

## Failure behavior

A negative World result, lost World, missing ACK after 30 seconds, unresolved
Master revocations or failed account save yields sticky `BLOCKED`. Admissions
stay closed. Late/foreign/duplicate acknowledgments cannot manufacture success.
There is no force-close, discard-money, automatic reopen or resume endpoint.
A failed profile save retains the latest captured resources in the concrete World
operation owner rather than dropping them when disconnect removes the peer.

Keep blocked processes/evidence available and resolve the underlying
store/session/recovery problem before planned termination. A crash/restart is a
separate recovery decision with the documented soft-state loss window, not proof
of a clean checkpoint. The operator API does not blindly retry an economic
mutation or roll back a transaction merely because its response was lost.

## Diagnostics

Status contains lifecycle state, bounded queued SQL count, ready-worker count,
stopped flag, unsettled domain names and last heartbeat age. `pending == 0` does
not mean RAM money is settled; e.g. a paused wallet can have no queued SQL but
still appear in `unsettled_domains`. Worlds reporting failed/draining/stopped
workers lose public readiness. World counters are a whitelist, not raw heartbeat,
configuration, per-account data, command bodies, paths or connection strings.

This is an observation of worker/domain state, **not an idle PG SQL/network
liveness probe** (`database_probe: false`). No SQL runs to serve status or per
simulation tick. Heartbeats are periodic; their age must be considered. Existing
pool/job budgets and failure/recovery owners are unchanged.

## Verification

```powershell
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite maintenance
python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite bootstrap
& ./tests/run-account-identity.ps1
& ./tests/run-smoke.ps1
```

The maintenance suite extends ordinary three-process startup acceptance. It keeps
a real client connected with dirty Yang/XP, invokes the actual authenticated HTTP
routes, verifies money/progression persistence and native worker closure before
success, checks same-ID operator replay, frozen account-file hashes and restart.
The fixture alone injects grinding income/XP; production drain/identity/RPC code
is unchanged by the harness.

A third native run holds an active PG wallet-table lock past worker SQL budgets.
It must produce `BLOCKED`, retain dirty wallet state and leave Master grant workers
running. Only this deliberately failed **disposable fixture** is forcibly cleaned
up afterward; that is not a runtime recovery path or successful graceful stop.
Focused injected cases cover missing/late/foreign/malformed ACK, timeout, World
loss, empty-token auth and account checkpoint failure. See
[evidence](../evidence/postgres-p3t/README.md). Linux, physical CEF, backup/restore,
controlled process handoff, sustained load/soak/import and cutover remain open.
