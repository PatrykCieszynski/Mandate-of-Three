# Package B — Combat i aktorzy

Plan wykonawczy z 2026-10-12. Baza: codex/spike-graduation, HEAD 60bc7af,
po Package A i zmianie polityki testów. To plan; implementacja B jeszcze nie ruszyła.
Obowiązują [kierunek projektu](project-direction.md),
[persistence policy](persistence-policy.md), [plan nadrzędny](spike-graduation-plan.md)
i [polityka testów](testing.md).

## Cel i odbiór

SpikeCombat3D przestaje posiadać równocześnie stan ataku gracza, AI/packs,
lifecycle mobów, input/targeting klienta i presentation. Pozostaje cienką fasadą
obecnych RPC, publikacji i jawnego wywoływania właścicieli operacji.
Zachowujemy działanie obecnego basic attack, mobów i Metina.

Nie zmieniamy wire/RPC paths, authority, reliable channels ani interwałów.
Nie zmieniamy balansu, timingów, fizyki, combo definitions, traces, reward policy,
checkpoint policy ani Metin DEAD/VFX. Target nadal jest identity {kind,id};
bez TargetManagera i target frame. Nie budujemy uniwersalnego Action System,
AI strategy framework ani DI frameworka. Package C, world split i persistence P2
pozostają osobnymi zakresami.

## Workflow i wielkość zmian

- Po rozpoczęciu implementacji tworzymy codex/spike-package-b z aktualnego
  codex/spike-graduation. Nie implementujemy na main.
- Każde cięcie poniżej ma osobny, sprawdzony commit. B2 i B3 można rozbić na
  kolejne commity, jeśli migracja zacznie mieszać niezależne odpowiedzialności.
- Nie robimy jednocześnie ekstrakcji attack state, AI i actor physics.
- Cały ukończony B integrujemy --no-ff do spike-graduation i usuwamy tylko
  zmergowany branch. Publikacja wymaga prośby użytkownika.
- Headless checks są dowodem kontraktów, a manualny combat playtest jest osobnym
  warunkiem odbioru milestone'u. Nie deklarujemy weryfikacji natywnego feel/CEF
  na podstawie zielonych suite'ów.

## B1 — PlayerCombatRuntime: przeniesienie stanu, bez rewrite zachowania

Aktualny endpoint ma dziewięć map attack state: _next_attack_ms,
_movement_unlock_ms, _combo, _combo_states, _pending, _sequences,
_active_attacks, _queued_attacks i _desired_facing.

Zastępujemy je jedną kolekcją runtime'ów per peer. PlayerCombatRuntime posiada
sequence, active action, pending impact, jeden queued intent, BasicAttackComboState,
desired facing i attack/movement deadlines. Display combo step wyprowadzamy
z istniejącego stanu, jeśli jest równoważny; nie utrzymujemy drugiej mapy dla testów.
Aktywna akcja i pending impact zachowują semantykę przyjętego swing, bez kopiowania
dwóch niezależnych wersji jego definicji/timingu/hit set.

Health, alive/dead, respawn i HitReactionState nie trafiają do tego runtime'u.
W B1 health/respawn mogą zostać u obecnego właściciela do actor split; nie tworzymy
nowego PlayerLifeState wyłącznie dla symetrii.

Przenosimy odczyty/zapisy i initialize/remove/cancel. Zachowujemy replay semantics,
frozen definition/yaw/stats dla przyjętej akcji, kolejność działań i wyczyszczenie
attack advance przy cancel. Logika begin/start/resolve nadal pozostaje w fasadzie
do B2. Nie dodajemy własnego tick, RPC, inventory ani persistence do runtime'u.

Odbiór: istniejące ACTION, FEEL2 i combat. Dostosowujemy ich setup i asercje
związane ze starymi mapami; nie zostawiamy aliasów ani lustrzanych map.
Zero nowych testów tylko dlatego, że powstał PlayerCombatRuntime.

## B2 — BasicAttackService: jedna istniejąca mechanika

Przenosimy intake/replay, preinput, queue/chaining, scheduling impact,
cancel, facing i hit resolution wraz z dotychczasowym CombatTraceResolver,
HitReactionResolver i legacy melee fallback. Serwis używa runtime'ów z B1.

SpikeCombat3D pozostawia uwierzytelniony RPC intake i niezbędne publiczne delegaty
używane przez World/NPC/gameplay. Serwis zwraca wynik potrzebny do obecnych
swing/hits/wait RPC; nie tworzymy event busa ani pipeline grafu.
Server attack advance uruchamia aktor gracza, a serwis ustala jego parametry.

Hit resolution wylicza CombatHitResult. MobSystem od B3 przyjmuje gotowy wynik,
aktualizuje HP/contribution/reaction/lifecycle i emituje death. Nie przenosimy
formuł damage do MobSystem. Do czasu B3 używamy obecnej konkretnej operacji moba,
bez równoległych właścicieli stanu.

Podział tick nie może zmienić wyników: pending impact ma zostać rozliczony raz
także po hitch, a mob hit/death/knockdown musi anulować przyszłą queued action.
Obecny przepływ expiry → respawn → pending impacts → mobs → queue → Metin →
snapshot jest punktem wyjścia migracji, nie kontraktem prywatnych metod w testach.
Jawny caller wywołuje etapy; sygnały służą do faktów/publikacji.

Odbiór: ACTION, FEEL2, combat; combat-trace/legacy przy zmianie tej ścieżki.
Zachowujemy wynikowy damage, multi-hit filtering, raz-na-swing, frozen yaw,
AS timing/advance, jeden buffer i cancel. Nie piszemy drugiej implementacji
tych scenariuszy jako unit suite serwisu.

## B3 + B6 — MobSystem, MobState i konkretne parametry contentu

Ten zakres dzielimy na małe commity: wspólny enum/parametry oraz przeniesienie
własności spawn/packs/AI/lifecycle/snapshot. B6 wykonujemy razem z generic mob
runtime, żeby dog assumptions nie stały się API nowego systemu.

MobSystem posiada live mobs, packs, allocatory ID, spawn/replacement/expiry,
shared aggro/leash/wander/return, lifecycle i mob snapshot capture/application.
Stan pojedynczego moba pozostaje na jego aktorze. Klient odtwarza moby z pełnego
snapshotu przez tego samego właściciela kolekcji; RPC nadal obsługuje fasada.
World jest composition root. Metin korzysta z operacji MobSystem zamiast
combat.dogs/packs; ewentualne delegaty pozostają tylko dla realnych callerów.

MobSystem nie zna XP, wallet, ground loot, SQL, player attack queues ani formuły
damage. Death event podpinamy w composition root do KillRewardResolver; zachowujemy
once-only death/contribution/reward i reconnect identity z A.

Jeden MobState zastępuje stringi i dotychczasowy enum w MobSnapshot, z zachowaniem
wire 0–6. Do MobDefinition przechodzą aggro_radius, attack_reach, attack_interval,
experience_reward oraz basic_attack (obecny AttackHitDefinition).
Content otrzymuje wartości odtwarzające obecne zachowanie. KillRewardResolver
czyta experience_reward z definicji; MobSystem nie przyznaje XP.
Nie dodajemy nowych profili zachowania, skill sets ani loot modelu.

Odbiór: istniejący mob_packs w smoke, PvE, Metin network; XP przy przeniesieniu
experience_reward. Zachowujemy prawa/rewards, replacement identity, leash,
wave expiry, target invalidation oraz kompaktowy format snapshotu.
Nie kopiujemy starych dogs/packs map na fasadę dla fixtures.

## B4 — ClientCombatController

Przenosimy selected_target, resolver/invalidation, autoattack, assist direction,
input, retry/sequence gating oraz obsługę client presentation do konkretnego
kontrolera klienta. HUD, drop visuals, swing/hit/reaction/XP feedback dostają
jednego właściciela lifecycle/disposal; istniejące CombatFeedback3D i WarriorVisual3D
pozostają używane, bez nowego frameworka presentation.

Fasada odbiera obecne RPC/snapshoty i przekazuje je kontrolerowi oraz MobSystem.
Core UI zachowuje dotychczasowe publiczne sygnały; nie robimy Package C przy okazji.
World korzysta z jawnych delegatów assist/cancel autoattack, bez dostępu do
prywatnych pól kontrolera.

Odbiór: combat/FEEL2, mob_packs/Metin target identity i właściwy istniejący
bridge/network flow. Target ginącego/usuniętego moba lub starej instancji Metina
jest czyszczony razem z autoattack; nie wraca sam po respawn.
Input ownership, mouse picking, camera i CEF sprawdzamy natywnie na odbiorze B.

## B5 — Chuda baza aktora, osobny gracz i mob

SpikeCharacter3D zawiera dziś Warrior/equipment/advance/player movement, a
SpikeWildDog3D po niej dziedziczy. Rozdzielamy to dopiero po ustaleniu właścicieli
z B2/B3; nazwy robocze: SpikeActor3D, SpikePlayer3D, SpikeMob3D.

- Actor: wspólne authoritative body plumbing, hit reaction/knockback,
  snapshot/interpolation i defending geometry.
- Player: player movement policy, attack advance/frozen facing, BODY overlap
  escape policy, equipment i Warrior presentation.
- Mob: własna konfiguracja movement body/visual oraz AI-facing actor data.
- Health/alive/dead/respawn są stanem życia aktora. Serwis ataku ich nie posiada;
  dodatkową klasę life state tworzymy tylko przy realnej potrzebie.

Baza nie zna potomka moba i nie posiada Warrior/equipment/autoattack.
Zachowujemy oddzielne BODY/defending colliders, layer/mask semantics, brak
bocznego slide podczas attack advance i pełne zamrożenie zwłok do respawn.
Migracja typów/callerów/resources odbywa się razem; nie utrzymujemy starych klas
ani pól wyłącznie dla zgodności z testami. Nie refaktorujemy World movement
controller ani camera przy okazji.

Odbiór: ACTION (BODY/advance/overlap/death freeze), combat/FEEL2, mob_packs/PvE
i Metin. Natywny combat playtest po całości: attack/chaining/AS, cancel/death/
respawn, crowd escape, finisher, targeting i NPC/input interop.

## Testy w trakcie extraction

Najpierw korzystamy z istniejących suite'ów. Nowy test dodajemy tylko wtedy,
gdy extraction odsłania konkretny kontrakt, którego dziś realnie nie pokrywamy.
Nie wymagamy pełnego line/path coverage PlayerCombatRuntime ani każdej nowej klasy.

Existing tests are regression evidence, not immutable API. During extraction,
preserve behavioral contracts, but freely rewrite or remove tests that assert
obsolete private state, implementation order, or ownership. Do not preserve
old internals solely to keep a test green.

Przed zmianą testu określamy chronione zachowanie, nie zachowujemy prywatnej nazwy.
Preferujemy przyjęcie/odrzucenie intencji, wynik damage/reaction, replikowaną
animation/action identity i brak dalszego działania po cancel/remove.
Synthetic time, kontrolowany aktor i fault injection mogą pozostać fixture setup.
Dopuszczalny test wnętrzności wymaga nazwanego bugu/inwarianty i uzasadnienia.

ACTION już sprawdza hitch-safe once-only impact i BODY/death freeze.
FEEL2 już przechodzi przez buffer, chaining, AS/facing, toggle i death/knockdown
cancel; combat pokrywa damage/reactions/replication/death/respawn.
Nie dublujemy tego dla B1. Cleanup po remove/disconnect jest kandydatem do
sprawdzenia luki podczas B1/B2, nie z góry zaplanowaną nową unit suite.

W każdym commicie: diff check i właściwe istniejące scenariusze.
Smoke/import przy zmianie source; extended network suites sekwencyjnie na 18098.
Nie uruchamiamy całego zestawu extended po każdym mechanicznym przeniesieniu.
Guard rozszerzamy o zakończone granice attack/mob/client/actor w istniejącym
skrypcie i jego kontraktach, bez testowania liczby klas lub prywatnych pól.
Na końcu B wykonujemy właściwy zestaw regresji i osobny manualny playtest.
