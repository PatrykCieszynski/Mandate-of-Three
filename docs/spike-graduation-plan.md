# Graduacja spike — zatwierdzony plan refaktoru

Zatwierdzony 2026-10-11. Baseline: `2fd5668`.
Cel: selektywnie usunąć dług production path First Region, zachowując działanie
gry po każdym integrowanym pakiecie. Kierunek gameplay i persistence pozostaje
opisany w [project-direction.md](project-direction.md) oraz
[persistence-policy.md](persistence-policy.md).

## Workflow branchy

Uzgodniony w tej rozmowie workflow dla tego refaktoru:

- `codex/spike-graduation` — nadrzędny branch integracyjny, utworzony z main.
- `codex/spike-package-a` — Package A, utworzony z brancha nadrzędnego.
- `codex/spike-package-b` — Package B, tworzony z aktualnego brancha nadrzędnego
  po ustabilizowaniu A.
- `codex/spike-package-c` — Package C, tworzony z aktualnego brancha nadrzędnego
  po ustaleniu potrzebnych API z A; może być realizowany niezależnie od B.

Etapy wewnątrz pakietu mają osobne, reviewowalne commity i właściwe sprawdzenia.
Sprawdzony pakiet integrujemy lokalnie przez `git merge --no-ff` do
`codex/spike-graduation`, po czym usuwamy wyłącznie zmergowany branch pakietu.
Main pozostaje zintegrowanym baseline do końcowego odbioru refaktoru.
Końcowa integracja nadrzędnego brancha do main również używa `--no-ff`.
Publikacja następuje na żądanie użytkownika; topic branch wymaga osobnej,
jawnej prośby o jego publikację. Nie usuwamy niezmergowanych branchy.

## Stałe granice migracji

- Zachowujemy server authority, prawa/ownership, revisions, atomowość i rollback.
- Endpointy mogą pozostać fasadami RPC. Nazwy węzłów, ścieżki RPC, authority,
  kanały i wire format pozostają stabilne podczas ekstrakcji.
- Sygnały służą do fan-out po zakończeniu operacji. Poprawność transakcji i cache
  nie zależy od kolejności subskrybentów.
- Nie budujemy DI frameworka ani uniwersalnego systemu akcji.
- Każdy stan ma jednego właściciela; nie utrzymujemy równoległych starych map
  wyłącznie dla zgodności testów.
- Nie mieszamy ekstrakcji z balansem, nową fizyką, nowym transportem snapshotów
  ani zmianą checkpoint policy.

## Package A — granice i ekonomia

| Etap | Zakres | Warunek zakończenia |
| --- | --- | --- |
| A1 | Transaction / authoritative state / publication | Operacja jawnie kończy commit i aktualizację RAM/cache przed powiadomieniami |
| A2 | Prywatne wywołania między modułami | Ekonomia, Inventory i pickup korzystają z ustalonych operacji i powiadomień |
| A3 | Mandate ↔ TinyMMO | Gameplay korzysta z jednego małego adaptera zamiast WorldServer.curr |
| A4 | Rewards / ground loot extraction | Combat nie posiada ekonomii ani live ground drops |
| A5 | Architecture regression guard | CI wykrywa powrót usuniętych zależności |

### A1 — zatwierdzone brzmienie

**W A1 kolejność commit → authoritative state/cache → notification → publication
będzie jawna w operacji aplikacyjnej. Właściciela tej operacji wybieramy zgodnie
z istniejącymi odpowiedzialnościami, bez wymuszania nowej warstwy tylko na
potrzeby refaktoru.**

Inventory `_send_state()` dziś również aktualizuje runtime equipment/combat
stats. Aktualizacja autorytatywnego cache musi zostać oddzielona od wysyłania
snapshotu. Dopiero po commit i aktualizacji stanu emitujemy konkretne fakty zmiany,
np. `inventory_changed(owner_id)` i `wallet_changed(owner_id)`; endpointy publikują.
Rollback nie emituje udanej zmiany. Naprawa snapshotu przy stale revision jest
osobną ścieżką. Zachowujemy account scope Storage i publiczną replikację broni.

### A2 / A3 — zależności

Nie zastępujemy cudzych `_store()`, `_send_state()` i `_send_snapshot()` samymi
publicznymi nazwami. Dostęp do repozytorium i operacji ma jawnego właściciela.
Jeden mały `MandateWorldServices` może pełnić rolę adaptera TinyMMO, udostępniając
np. `player_for_peer()`, `owner_id_for_peer()`, `runtime_stats()` oraz konkretne
referencje do potrzebnych usług. Nie eksponuje dowolnych wnętrz serwera.
Nie tworzymy osobnych interfejsów provider/repository dla każdej zależności.

### A4 — odpowiedzialności

- `KillRewardResolver`: odbiorca i nagroda konkretnego killa.
- `GroundLootSystem`: live drops, ownership, reservation, expiry i pickup.
- Operacja progression: XP i dirty state; pełny extraction checkpoint runtime
  z WorldDatabase jest odłożony do P2.

Combat pozostawia rozstrzygnięcie śmierci i contribution, ale nie zna SQLite,
nie publikuje Inventory, nie generuje itemów, nie przyznaje XP i nie spawnuje Yang.
Zachowujemy aktualnego właściciela stanu postaci po disconnect/relog, zamiast
korzystać ze starej referencji PlayerResource. Atomowy claim i ochrona przed
ponownym odebraniem pozostają w persistence. Nie dodajemy trwałego rejestru killów.
Nie wymuszamy trzech nowych klas w pierwszym commicie extraction.

Odbiór: dotychczasowy combat oraz prawa do nagród, pickup replay, rollback,
disconnect/relog. Attack timeline, AI i fizyka pozostają poza refaktorem A.

## Package B — Combat i aktorzy

| Etap | Zakres | Właściciel |
| --- | --- | --- |
| B1 | Stan basic attack | PlayerCombatRuntime |
| B2 | Intake, preinput, queue, scheduling, chaining, cancel, hit resolution | BasicAttackService |
| B3 | Spawn, packs, AI, aggro, lifecycle, mob snapshots | MobSystem |
| B4 | Targeting, autoattack, input, client feedback | Client combat controller |
| B5 | Chuda baza oraz player/mob split | Actor / Player / Mob |
| B6 | MobState i parametry moba | Jeden enum i MobDefinition |

PlayerCombatRuntime posiada sequence, active action, queued intent, combo state,
desired facing i movement/action locks. Nie posiada health ani respawn.
Health, alive/dead i respawn należą do życia aktora; istniejący HitReactionState
pozostaje na aktorze.

BasicAttackService implementuje obecny basic attack. Wspólną abstrakcję akcji
rozważamy dopiero po realnym drugim zachowaniu, np. skillu/channelingu.
MobSystem nie posiada loot, XP, damage calculation ani player attacks.
Korzystamy z istniejących CombatTrace i HitReaction resolverów.

Chuda baza aktora ma authoritative movement body, hit reaction, knockback oraz
snapshot/interpolation plumbing. Player posiada movement policy, attack advance,
equipment, Warrior presentation i BODY escape policy. Mob posiada movement body
config, mob visual i AI-facing runtime data. Baza nie zna swojego potomka moba.

MobState zachowuje obecne wartości wire 0–6. Razem z generic mob runtime do
MobDefinition przechodzą aggro_radius, attack_reach, attack_interval,
experience_reward i basic_attack. Dane odtwarzają obecne zachowanie.
Nowe strategie AI wymagają rzeczywistego drugiego zachowania.

Odbiór: ACTION, FEEL2, combat, właściwe pack/Metin/actor checks oraz manualny
combat playtest. Pilnujemy hitch-safe impact, pojedynczego buffered intent,
cancel przez death/knockdown, full-motion advance, overlapa, finishera i respawn.

## Package C — Core UI

1. UiCommandSession: IDs, pending, reply, timeout, reload/disconnect, late reply.
2. NpcDropTargetProjector: projekcja i data-driven targety z jawnymi zależnościami.
3. ItemUiAdapter: wspólne modelowanie Inventory, Equipment i Storage.
4. Spójne fragmenty NPC, Shop i Upgrade, wyciągane pojedynczo.
5. Rename CoreUiController po ograniczeniu go do kompozycji i wspólnej polityki UI.

Wallet może pozostać prostym dispatcher.set_domain(). Nie tworzymy klasy per
domena dla symetrii. Web bridge, window i drag primitives zachowują odpowiedzialności.

Odbiór: bridge/UI contracts, właściwe flow networkowe i natywny CEF pass po
milestone. Zachowujemy command lifecycle, exact service ID, drag/drop, keyboard
ownership, tooltip modifier i otwieranie okien.

## Architecture regression guard

Wprowadzamy `tools/check-mandate-boundaries.ps1` przy zamknięciu A, a zakres
rozszerzamy przy B/C. Sprawdza konkretne zakazane połączenia:

- WorldServer.curr w gameplay Mandate poza jednym dokładnym plikiem adaptera.
- Cudze _store(), _send_state(), _send_snapshot().
- Dostęp do world._camera i world._npc_approach po zastąpieniu ich ustalonym API.

Lokalne prywatne metody pozostają dozwolone. Scope to kod Mandate, z rozdzieleniem
upstream TinyMMO i fixtures. Guard egzekwuje usuniętą granicę od jej zakończenia;
nie tworzymy szerokiej whitelisty istniejącego długu. CI ma osobny check
`Architecture boundaries: PASS`.

## Weryfikacja i kolejne decyzje

Domyślnie git diff --check i mały smoke. Extended suites dobieramy do kontraktu,
a network suites na wspólnym porcie uruchamiamy sekwencyjnie. Nie dokładamy pixel
snapshots, geometry/animation snapshots ani nowych balance assertions do smoke.
Testy prywatnych map/metod przenosimy z logiką, zachowując scenariusze zachowania.

Po B ponownie oceniamy SpikeWorld3D. WorldMovement3D / ClientWorldController
powstaną tylko jeśli pozostałe odpowiedzialności tego wymagają.
Pełny extraction Wallet/Progression z WorldDatabase, starter kit i dev sword
policy to osobny P2. Content registry, protocol manifest i upgrade-view split
wchodzą wraz z konkretną potrzebą contentu/protokołu/upgrade, nie w tej migracji.

Pierwszy zakres implementacji: A1. Pierwszy odbiór całego milestone: Package A.

## Realizacja A1 — 2026-10-12

A1 jest zaimplementowany na `codex/spike-package-a`. Właściciele operacji zostali
dobrani zgodnie z obecnym kodem: Shop/Upgrade zachowują swoje operacje aplikacyjne,
Inventory obsługuje własne komendy, a WorldDatabase nadal wykonuje atomowe
operacje SQL i akceptuje wallet RAM. Nie dodano nowej warstwy ani klasy.

- `refresh_authoritative_state(peer_id)` przygotowuje snapshot, runtime equipment
  cache i server weapon state przed powiadomieniem.
- `_send_state()` konsumuje przygotowany snapshot, nie odświeża cache combatu.
- Sygnały `inventory_changed(owner_id)` i `wallet_changed(owner_id)` służą do
  publikacji po zakończonej operacji; nie sterują commit ani cache.
- Account Storage przygotowuje wszystkie dotknięte postacie przed pierwszym
  powiadomieniem. Equip/move/pickup przygotowują cache po udanej operacji.
- Entry i odrzucone/stale komendy korzystają z jawnej resynchronizacji, bez
  fałszywego faktu commitu. Błąd odczytu unieważnia runtime cache.
- Bez zmian pozostają wire/RPC paths, transakcje SQL, revision/ownership,
  checkpointy oraz attack timeline/fizyka.

Weryfikacja A1: git diff --check, domyślny smoke (10 Godot + 74 Web UI), Shop,
Upgrade, progression, Yang i web-inventory network; suite'y sieciowe wykonane
sekwencyjnie. Testy obserwują stan przed publisherami, sprawdzają brak cache
side-effects podczas publikacji oraz brak committed-change facts przy
rollback/rejection. Fixture Upgrade po bezpośrednim seedzie SQL używa jawnego
resynchronize zamiast polegać na side-effect publikacji.

A2–A5 pozostają do wykonania: kolejne prywatne cross-calls, adapter TinyMMO,
rewards/ground loot i architecture guard. Package A nie jest jeszcze zamknięty.
