# Local channel transfer

## Contract (before implementation)

Stage 5 is a same-process, same-map PUBLIC channel handoff, not cross-World C5
fencing. Only already loaded accepting channels may be selected. No provisioning,
private dungeon entry, new SQL schema or economic operation identity is added.

- The current authenticated session owns one server-issued attempt and session
  epoch. Duplicate start/status cannot extend its countdown or reservation.
- A five-second cancellable countdown reserves capacity but retains the source
  actor. Movement, attack, damage, death, active NPC interaction or invalid target
  abort it. Combat must have been quiet for ten seconds before starting.
- New character economic mutations are gated during the attempt. Read-only
  receipt recovery remains available. Transactions admitted earlier already
  finish synchronously on the current single-threaded application boundary.
- Revalidate, checkpoint dirty progression/pending Yang, then fence and remove
  the source without yielding. A failed checkpoint releases the destination and
  leaves the source actor intact; successful checkpoint writes are not undone.
- Only the reserved destination may activate. Carry position, facing, HP and
  combat options; refresh authoritative equipment/wallet/progression there.
  Never heal via channel switching. Old map RPC paths have no actor after fencing.
- Loading has the existing bounded entry deadline. Cancellation after fencing
  cannot resurrect the source; disconnect/relogin recovers through normal entry.
- Disconnect/replacement releases the attempt. Stale attempt/epoch messages cannot
  cancel a later attempt or hydrate a replacement session. State is session-local,
  bounded, and is not a durable economic receipt.

The existing native game controls expose a small channel panel; CEF presentation
and economic journals remain unchanged. This is not a clean native-input or
cross-process recovery claim until explicitly verified.

## Implemented flow

`Change CH` beside `Options` opens the native connection panel. Refresh also
queries the current attempt, so hiding/reopening the panel never starts another
attempt. Close/Escape hides it; the separate Cancel action cancels only the exact
attempt/epoch. Movement and attack remain usable to interrupt the countdown.
An open authoritative NPC interaction must be closed first. Channel selection
does not create another map or use the legacy 2D teleport path.
Fresh nonzero movement intent prevents starting a countdown. Once counting down,
an accepted nonzero input cancels immediately after sequence validation, even
against a wall or before physics runs. Intent expiry matches normal simulation;
the displacement check remains a fallback for other movement sources.

`InstanceManagerServer` admits/rate-limits three explicit RPC actions
(`start`, `cancel`, `status`). A small local transfer owner coordinates reservation,
eligibility, checkpoint and source fencing. The existing map join guard checks the
transfer's loading phase before consuming its reservation. Map join refreshes
Inventory/runtime equipment and wallet, then initializes combat from the carried
HP/position/facing/options before its first combat snapshot. Duplicate join is
still rejected by ordinary membership checks.

New Inventory/Storage, ground item/currency pickup, critical spend, Shop, Upgrade,
Marketplace/Exchange and generic data mutations are gated. Receipt lookup on the
dedicated economy endpoints remains read-only and available while the source
exists. A lost command response remains uncertain in the existing client journal;
recreated client adapters discover the same receipt at the destination. No new
economic receipt is created merely for changing CH.

## Verification and limits

The existing two-client local-map fixture covers full/draining targets, duplicate
start, stale cancel/epoch, early join rejection, cancel/movement/combat/target-drain
abort, injected checkpoint failure, live Inventory RPC admission, blocked Yang
pickup/spend, final XP/Yang checkpoint, retained HP/combo options and exactly one
activation. It deliberately loses an Inventory move response before handoff and
recovers the original journal/receipt after actual client map recreation without
another revision increment. The reserved-entry variant rejects public handoff
from a private copy.
Real movement RPC regressions also cover held WASD at start and new input before
the deadline with physics held stationary; an expired intent does not lock entry.

The native session fixture covers real relog/disconnect during countdown, delayed
old disconnect, post-fence loading timeout and relog with the saved wallet. These
extend existing suites; no default test suite or timing/balance assertion is added.

One offscreen Windows Vulkan Mobile client with installed CEF and
`--render-thread separate` completed the two-client transfer/recovery scenario;
CEF reported Vulkan accelerated OSR and recreated its browser. It also logged
empty-image texture updates and render-thread `finalize` errors at recreation/
shutdown, as observed in the earlier native preview. This is functional protocol
evidence, **not a clean renderer lifecycle pass**. Physical mouse/keyboard focus,
manual countdown UX, Linux and cross-process transfer are not verified here.

First Region remains at two public copies. No simulation performance change,
PostgreSQL, cross-process ownership, persisted transfer journal or full C5 async
command barrier is implied by this local implementation.
