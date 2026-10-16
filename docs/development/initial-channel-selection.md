# Public CH discovery and initial selection

## Contract before implementation

Authenticated clients currently enter automatically. This slice exposes a bounded
public catalogue and an explicit initial channel choice through the existing
InstanceManager RPC boundary. The existing pre-world Transition screen presents
the choice; in-world CEF/gameplay windows are unchanged.

Catalogue records contain only public channel number, load state and population /
capacity. They do not expose private runs, membership, host addresses or runtime
instance IDs. Choosing a channel is a request: current session, target policy,
capacity, readiness, draining and deadline are revalidated. A stale/full/removed
explicit choice returns unavailable, never silently reroutes to another channel.
Automatic initial selection remains an explicit option for existing programmatic
clients and uses the current bounded provisioning policy.

Choosing does not reserve capacity until accepted. The choice window expires
after 30 seconds without renewal by refresh; accepted entry then uses the existing
map-load deadline. Disconnect/replacement retires the choice. Requests after an
actor joined cannot transfer it. Duplicate/late messages cannot spawn or replace
an assignment. Request correlation is ephemeral, bounded per session and separate
from durable economic operation IDs. No Gateway/Master ticket or economy schema
changes, party selection, active-player transfer or channel stickiness are added.

Verification extends current network/session fixtures for real catalogue/choice
RPCs, private exclusion, stale/full/draining choice, expiry/reconnect, replay and
no mutation after join. UI tests target public behavior rather than node geometry.
Rollback deploys matching client/World builds; no persistent migration is needed.

## Implemented flow

World authentication opens a 30-second choice window and sends the initial
catalogue on InstanceManager. Refresh is read-only and never extends that window.
Each row has exactly `channel_id`, `state` (available/loading/full/draining),
`population` (including pending entries), and `capacity`. Only owned PUBLIC
copies of the current default entry map are listed. No other map/run discovery
is implemented here.

`request_channels` and `request_initial_channel` share a monotonically increasing
transport request sequence per authenticated peer. Old/duplicate IDs are ignored
before rate limiting; each fresh request can receive one result. IDs are int32
positive, state is one counter per peer, and requests share an eight-per-second
limit. This is not durable command admission. Retry uses a new transport ID with
the same desired channel; an accepted pending choice can be replayed safely.

Positive channel IDs select that exact current public copy. Zero requests automatic
selection through existing balancing/provisioning. Explicit unavailability leaves
the choice window open for refresh/another choice. Automatic failure preserves the
prior connection-close behavior. An accepted reservation consumes the choice
window and starts the map entry deadline; acknowledgement precedes publication.
An accepted assignment replay does not recreate an already loaded client map.
Joined actors cannot use the selector to move or disconnect themselves.

The existing native pre-world Transition overlay shows channel buttons, automatic
selection, refresh and Back to login. Full/draining buttons are disabled. A stale
choice displays a server error and lets the player refresh. Late catalogue replies
cannot reopen the picker while an accepted selection is loading. Normal Gateway
entry opts into this picker; programmatic clients retain explicit automatic mode.
In-world CEF, Inventory, Gateway HTTP and Master tickets are unchanged.

## Verification — 2026-10-16

- Smoke: 10 Godot fixtures, 85 Web contracts and architecture guards.
- Existing two-client local MapInstance fixture uses the real catalogue and choice
  RPCs to enter CH1/CH2, then retains isolation/foreign RPC rejection and cross-copy
  economic settlement. Reserved-entry mode proves private records are excluded.
  A post-spawn initial-selection RPC cannot disconnect or replace either actor.
- Focused existing cases cover full/draining/unknown choice without fallback,
  accepted pending replay, changed choice rejection, bounded request deduplication,
  expired windows, and refresh without deadline renewal. Controlled fixtures now
  keep an idle grace while preparing empty private hosts, avoiding a race with
  the existing one-second retirement timer before test membership is installed.
- Native authenticated session fixture verifies a client deliberately waiting at
  the chooser, actual refresh RPC, no reservation/actor, fixed deadline and normal
  disconnect/Master retirement on expiry. Original ticket/session/load-timeout,
  persistence and relog tests remain green. World RPC ingress also passed.
- Normal Gateway/Master/World `run-items.ps1 -WithSession` passed in a disposable
  complete project: equip/relog and graceful World shutdown. Original account/DB
  hashes were unchanged; owned disposable outputs were cleaned with the repo tool.
- One offscreen Vulkan Mobile visual capture at 1280×720 and 1920×1080 was inspected:
  labels/actions fit, and a full channel is visibly disabled. This is visual QA,
  not physical mouse/keyboard/IME acceptance. The separate-render-thread preview
  also logged texture-update/render-finalize errors on resize/shutdown; no clean
  native lifecycle claim is made. Existing certificate/resource warnings remain.

Deploy matching client/World builds because InstanceManager RPC signatures changed.
No Linux, release export or in-world CH transfer acceptance is claimed. First Region
keeps its two-public-copy production cap. No new suite/default CI expansion.
