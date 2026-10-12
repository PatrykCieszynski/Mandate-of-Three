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

Szczegółowy plan wykonawczy i zasady migracji istniejących testów:
[Package B](spike-package-b-plan.md). Wykonanie na osobnym branchu z aktualnego
spike-graduation; poniżej pozostaje zatwierdzony zakres nadrzędny.

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
Health/alive/death należą do właściwego actor/life ownera; HitReactionState
pozostaje na aktorze. Player respawn to player lifecycle, a mob replacement/respawn
należy do MobSystem; wspólna baza nie unifikuje polityki respawnu.

BasicAttackService implementuje obecny basic attack. B2a (intake/queue/timing/cancel)
i B2b (impact/hit path) mają osobne commity i używają istniejących resolverów.
Death fact MobSystem przekazuje zamknięty result bez actor reference. Kontroler
klienta obejmuje input/targeting/basic-attack presentation; ground loot visuals
i XP/progression feedback mogą zostać przy fasadzie do naturalnej ekstrakcji. Wspólną abstrakcję akcji
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
Testujemy kontrakt i zachowanie. Wnętrzności sprawdzamy tylko przy konkretnym bugu
lub krytycznej inwariancie, której nie da się sensownie sprawdzić z zewnątrz.
Priorytet: existing behavior tests > nowe integration tests > unit testy
implementacji. Nowe przypadki wymagają nowego kontraktu, konkretnego bugu,
krytycznej inwarianty albo ryzyka niepokrytego przez istniejące suite'y.
Nowa klasa/extraction sama w sobie nie uzasadnia testów.

W B PlayerCombatRuntime i ekstrakcje chronią przede wszystkim istniejące
ACTION/FEEL2/combat/network. Nowe unit cases tylko dla niepokrytych ryzyk
buffered intent, cancel, hitch-safe impact i cleanup po remove/death.
Nie utrwalamy starego układu prywatnych map/metod podczas przenoszenia logiki;
zachowujemy scenariusze zachowania. Szczegóły: [testing.md](testing.md).

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

Po commicie A1 pozostały do wykonania: kolejne prywatne cross-calls, adapter TinyMMO,
rewards/ground loot i architecture guard. Zamknięcie pakietu opisano poniżej.

## Package A — zamknięcie 2026-10-12

A1–A5 ukończone. Package A integrujemy lokalnie do codex/spike-graduation,
bez integracji do main i bez publikacji topic branchy.

- A2: world posiada jawne gameplay_camera(), cancel_npc_approach() i
  has_line_of_sight(); Combat udostępnia is_player_alive(). Naprawa Currency jest
  jawną operacją resynchronize. Zniknęły prywatne cross-calls objęte planem.
- A3: jeden MandateWorldServices jest przekazywany z composition root do
  endpointów/encountera. Tylko jego plik zna WorldServer.curr w tym production
  path. Adapter odczytuje aktualne sesje i store'y, nie zatrzymuje starych
  referencji przy reconnect/fixture store swap. item_domain_ready() zachowuje
  dotychczasową granicę physics-only fixtures bez oddawania Combatowi store'u.
- A4: Combat emituje mob_died po runtime death guard i lifecycle/respawn ticket.
  KillRewardResolver wybiera contribution winner (remis: niższy stable owner ID)
  i dotychczasowy roll; GroundLootSystem posiada live item drops, rights, expiry,
  snapshot i pickup. Yang pozostaje w istniejącym Currency endpoint.
  WorldDatabase.award_experience() jest tymczasowym właścicielem operacji
  progression: RAM → dirty → fact. Resolver wybiera aktualny resource po
  disconnect/relog; Combat pozostaje fasadą dotychczasowego XP RPC.
- SQL claim przyjmuje przygotowany ItemInstance, waliduje UID/owner/definition
  i atomowo zapisuje receipt/item/placement. Nie generuje już iron_sword/affix.
  Starter kit i dev sword policy pozostają odłożone zgodnie z P2.
- A5: tools/check-mandate-boundaries.ps1 egzekwuje wskazane production scopes,
  jeden dokładny wyjątek adaptera, zakaz prywatnych cross-calls/pól świata
  i zakaz persistence/reward/ground state w Combat. Default smoke i osobny
  krok CI uruchamiają guard oraz jego pozytywne/negatywne kontrakty.
  Starsze TinyMMO modules i fixtures nie są szeroką whitelistą naruszeń:
  są osobnym, jawnie nieobjętym tym refaktorem zakresem.

Weryfikacja: import Godota, diff check, architecture guard/contracts, default
smoke (10 Godot + 74 Web UI), PvE/ground claim, XP/checkpoint/disconnect, Yang,
progression, Metin network, ACTION, FEEL2, combat, Shop, Upgrade i web-inventory.
Suite'y sieciowe wykonane sekwencyjnie. Zmiany RPC paths/wire, attack timeline,
physics policy, balance i checkpoint intervals nie należały do pakietu.

Przy weryfikacji odtworzono PvE timeout także na źródłach sprzed A4. Fixture
utrzymywało stały kierunek mimo full-motion advance; teraz celuje kolejne
intencje w poruszającego się moba, zachowując frozen yaw przyjętego swing.
XP fixture czeka na can_move zamiast dawnego 0.5 s i resetuje własną geometrię
przed kolejnym kontrolowanym killem. Metin fixture rozdziela działania
contributorów i obserwuje spawn nagrody przed niezależnym autolootem Yang.
Asercje ownership, damage/replay, rollback, once-only rewards, checkpointów
i disconnect zostały zachowane. Native CEF/subjective feel pozostaje odbiorem
właściwych kolejnych milestone'ów; ten pakiet weryfikowano headless.

Kolejne pakiety B i C mają osobne branche z aktualnego spike-graduation.
World split i pełny extraction Wallet/Progression z WorldDatabase nadal są
odłożone do ponownej oceny/P2, zgodnie z zatwierdzonym planem.

## Package A boundary follow-up — 2026-10-12

Krótki follow-up z review brancha eb042e0, na
codex/package-a-boundary-followup, integrowany do spike-graduation.

- Inventory accept_committed_change(peer_id) posiada refresh authoritative
  snapshot/equipment/cache i własny inventory_changed. Shop, Upgrade i pickup
  nie znają protokołu refresh + emit i nie emitują cudzych sygnałów.
- Currency accept_committed_change(peer_id) emituje własny wallet_changed po
  przyjęciu committed balance do RAM przez istniejącą operację ekonomii.
  Shop/Upgrade nadal jawnie wykonują commit + wallet RAM → Inventory acceptance
  → Currency acceptance. Sygnały pozostają fan-out, nie orkiestracją.
- Storage nadal przygotowuje wszystkie dotknięte postacie przed pierwszym
  powiadomieniem, wewnątrz właściciela Inventory. Rejection/stale/entry nadal
  używają resynchronize bez faktu udanego commitu.
- WorldDatabase udostępnia konkretne upgrade_candidate, storage_snapshot,
  transfer_storage i RAM-only pending_progression_player. Gameplay nie tworzy
  store'ów z surowego .db; adapter nie odczytuje dirty_progression. Konkretne
  economy/progression i item_store() pozostają bez nowej warstwy DI.
- Guard odrzuca surowe .db, dirty_progression (także w adapterze), cudze emisje
  inventory_changed/wallet_changed i odczyt pola item_store poza dokładnym
  adapterem. Kontrakty obejmują dozwolone API, własne emisje, multiline naruszenia
  i zakazane wnętrzności w samym adapterze.
- Pozostałość A4: GroundLootSystem nadal koduje weapon roll bonus 1..9,
  weapon_attack i attack affix. Generic SQL claim nie oznacza generic live drop
  payload. Cleanup dopiero przy pierwszym realnym non-weapon ground dropie.

Weryfikacja: diff check, architecture guard/contracts, default smoke
(10 Godot + 74 Web UI), Shop, Upgrade, PvE/ground pickup, Yang, web-inventory
(Storage/equipment) i XP/checkpoint/disconnect; suite'y sieciowe sekwencyjnie.
Dodano kontrakt RAM-only query oraz priorytetu current session / pending resource /
fallback i bieżącej referencji persistence po podmianie. Bez zmian wire/schema,
checkpoint policy, attack timeline i fizyki. B/C pozostają osobnymi milestone'ami.
