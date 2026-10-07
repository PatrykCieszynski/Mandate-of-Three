# Open-MT2 jako referencja dla Mandate of Three

Data analizy: 2026-10-07. Repozytorium: [willianmarquess/open-mt2](https://github.com/willianmarquess/open-mt2).
Przeanalizowany snapshot: commit `8d8800d470f0b69221886723eb5877a2ed9d9d8d`
z 2026-08-18, `Merge pull request #262 from dimabirca/fix/non-weapon-melee-attack`.
Odnośniki poniżej są przypięte do tego commita.

## Wniosek i zakres

Open-MT2 jest przydatną referencją reguł serwera: egzemplarzy przedmiotów,
ekwipunku, walidacji ataków, zachowania mobów i lootu na ziemi. W Mandate of Three
zachowujemy transport oraz cykl sesji TinyMMO i implementujemy własną domenę
gameplayu w Godot. Open-MT2 nie dodajemy jako zależności runtime ani drugiego backendu.

To analiza źródeł i wybranych testów, nie pełny audyt projektu. Sprawdzono modele
Item/ItemState/Inventory, usługi move/drop/pickup/shop, zapis i cache przedmiotów,
atak gracza i obliczanie obrażeń PvE, walidację ruchu, Behavior/Monster,
DropManager oraz dokumentację questów i pakietów. Nie instalowano zależności,
nie uruchamiano serwera, MySQL/Redis ani testów Open-MT2. Zaobserwowane ryzyka
wynikają z kodu; nie są wynikami odtworzonych exploitów.

[README](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/README.md)
opisuje projekt edukacyjny, dopuszczający odstępstwa od oryginalnego Metina.
Dlatego traktujemy go jako materiał do projektowania, a nie specyfikację zgodności.

## Co faktycznie jest w kodzie

| Obszar | Zaobserwowany stan | Zastosowanie u nas |
| --- | --- | --- |
| Przedmioty | Prototyp `vnum`, osobne `dbId`, właściciel, pozycja, okno, ilość, 3 sockets i 7 par typ/wartość atrybutu. | Rozdzielić ItemDefinition od ItemInstance; identyfikator egzemplarza nadać przed włożeniem do ekwipunku. |
| Inventory/equipment | Siatka stron 5×9, wielopolowe przedmioty, wydzielone sloty wyposażenia, zdarzenia equip/unequip, przenoszenie i split stacków. | Przenieść reguły własności, slotów i stacków; rozmiar siatki jest decyzją UI, niezależną od 3D. |
| Bonusy | Pola egzemplarza są zapisywane i wysyłane w pakietach. Equip applies iteruje po bonusach prototypu. | Zbudować własne generowanie affixów i kalkulację statystyk instancji. Sam zapis bonusu nie wystarczy. |
| Ulepszanie/reroll | Są `refineId`/`refineSet` i metadane prototypów; w przejrzanym `src` nie znaleziono usługi refine ani rerollu atrybutów. | Zaprojektować własny UpgradeService i RerollService. Nie zakładać, że można przeportować gotowe +0…+9. |
| Walka | Klient wskazuje cel i skill; serwer liczy obrażenia, sprawdza stan i ogranicza częstotliwość. Melee ma kontrolę odległości. PvP w PlayerBattle jest TODO. | Własny AttackRequest oraz walidacja świata, zasięgu, czasu i wyposażenia; najpierw PvE. |
| Ruch | Limit długości pojedynczego zgłoszenia, budżet przebytej odległości dla zgłoszeń pozycji, korekta klienta po odrzuceniu. | Serwerowa walidacja ruchu 3D, z uwzględnieniem kolizji i wysokości. |
| AI | Idle/wander, wyszukiwanie celu, follow, attack, powrót, stun, reakcja grupy, udział w obrażeniach. | Mała maszyna stanów moba plus NavigationAgent3D i serwerowe timery. |
| Loot | Common drops według rangi/poziomu, domyślny drop moba, gold, modyfikatory szans; osobna encja na ziemi. | Proste DropTable i GroundLootInstance, niezależne od grafiki. |
| Pickup | Typ encji, ta sama area, odległość, prawa do podniesienia, pełny inventory, ochrona przed ponownym pickupem. | Zachować wszystkie te niezmienniki; UID właściciela zamiast nazwy. |
| Persistence | Osobne rekordy itemów, kolejka update/delete, flush z odtworzeniem kolejki po błędzie. | Własny adapter SQLite i atomowe operacje zmieniające item oraz koszt. |
| Quests | Klasy TypeScript, stany i zdarzenia LOGIN/KILL/CLICK itd., fasady gracza/NPC i osobne mechanizmy dialogu. | Inspirować się zdarzeniami domenowymi; questy pozostają poza pierwszym spike'em. |

Źródła: [Item](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/item/Item.ts),
[ItemState](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/state/item/ItemState.ts),
[Inventory](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/inventory/Inventory.ts),
[MoveItemService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/MoveItemService.ts),
[PlayerApplies](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/PlayerApplies.ts),
[PlayerBattle](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/battle/PlayerBattle.ts),
[quest docs](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/docs/quests.md).

## Najważniejsza różnica względem obecnego forka

Nasze `source/common/gameplay/items/inventory.gd` ma już osobne wpisy
`slot_uid -> {id, a}`, więc nie zaczynamy od pustego modelu. Jednak:

- `id` oznacza definicję z ContentRegistryHub; `next_uid()` nadaje lokalny numer
  wpisu na podstawie aktualnej zawartości torby, a nie trwały globalny UID itemu;
- `normalize()` zachowuje `id`, `a` i pinned; nowe pola upgrade/affixes/sockets
  trzeba jawnie uwzględnić, inaczej znikną podczas odczytu zapisu;
- `EquipmentComponent` i endpoint `item.equip` operują na ID definicji;
  `remove_one_by_id()` wybiera pierwszy pasujący egzemplarz;
- equipment zapisuje `slot -> item_id`, a statystyki i wygląd pochodzą z Resource;
- `RewardService` przyznaje loot bezpośrednio do inventory uczestników zabójstwa,
  bez etapu przedmiotu na ziemi.

To oznacza, że dwa miecze tej samej definicji z różnymi bonusami nie są poprawnie
adresowane przez obecny przepływ equipu. Dopisanie bonusów do Resource zmieniłoby
definicję współdzieloną przez egzemplarze. Potrzebny jest rework domeny, endpointów,
zapisu i projekcji UI, niezależnie od zmiany Node2D na Node3D.

## Wzorce warte przejęcia i ich granice

### Przedmiot i operacje ekwipunku

W Open-MT2 `Item.getId()` zwraca ID prototypu, a `getDbId()` identyfikator rekordu.
Nowy item otrzymuje `dbId` dopiero po INSERT. Własny ItemInstance powinien dostać
UID przy utworzeniu i zachować go podczas equipu, lootu i zapisu. Pozycja w torbie
oraz runtime ID encji sieciowej nie powinny pełnić tej roli.

Proponowany kontrakt do implementacji:

```text
ItemDefinition: definition_id, nazwa, slot, base_stats, stack_limit, affix_pool
ItemInstance: uid, definition_id, owner_character_id, location, position,
              amount, upgrade_level, affixes[], sockets[], revision
Equipment: slot -> item_uid
```

UID i `owner_character_id` są niezależne od peer_id połączenia. `location` określa
jedno aktualne miejsce itemu. Zwykłe materiały mogą się stackować, jeśli ich stan
instancji jest zgodny; gear z indywidualnymi rollami pozostaje niestackowalny.
Nie potrzebujemy metinowych `attributeType0…6` jako sztywnego schematu ani
osobnej definicji każdego poziomu ulepszenia. Jawne `upgrade_level` i kolekcja
affixów lepiej odpowiadają planowi PoE-lite.

W sprawdzonym snapshotcie `Item.create()` zeruje atrybuty instancji;
`PlayerApplies.addItemApplies()`/`removeItemApplies()` czytają `item.getApplies()`
z prototypu. Pola losowych bonusów nie dowodzą gotowego systemu ich losowania ani
wpływu na statystyki. To istotna luka dla naszego celu.

### Atak i ruch

[CharacterAttackService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/CharacterAttackService.ts)
rozwiązuje virtual ID celu, a
[Player.attack](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/Player.ts#L643)
pilnuje stanu i czasu. Kontrola dystansu jest w
[strategii PvE](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/player/delegate/battle/PlayerBattleAgainstMobStrategy.ts#L181).
To dobry podział odpowiedzialności, ale wzory obrażeń i jednostki Metina nie są
naszym docelowym balansem.

Nasz AttackRequest powinien nieść cel, rodzaj akcji i numer żądania, a serwer
sprawdzać instancję świata, żywy stan obu stron, cooldown, zasięg/kolizję oraz
aktualny equip. Klient odtwarza animację i efekt wyniku. Atak wielu przeciwników
powinien wynikać z jednej legalnej akcji/AoE. Test Open-MT2 dopuszcza pierwszy
hit na nowym celu wewnątrz cooldownu, więc jego throttle nie jest globalnym
limitem pojedynczych swingów do skopiowania bez decyzji projektowej.

[CharacterMoveService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/CharacterMoveService.ts)
wywołuje `Player.isMoveAllowed()`. Istnieje kontrola skoku pozycji i budżet
odległości, ale budżet jest pomijany dla typu MOVE; kod rozróżnia zadanie celu
marszu od zgłoszenia bieżącej pozycji. Nie przenosimy tego mechanicznie do 3D.
Nasz serwer musi kontrolować prędkość i dozwoloną przestrzeń, a replikacja
potrzebuje jawnego rozróżnienia intencji, stanu i korekty klienta.

### AI, udział w walce i loot

[Behavior](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/mob/behavior/Behavior.ts)
jest dobrą listą minimalnych zachowań: roam, acquire, chase, attack, return.
Ruch operuje na płaszczyźnie i testach blokady mapy. U nas przełożymy stany na
NavigationAgent3D; nie przejmujemy algorytmów współrzędnych i jednostek map Metina.

W `Behavior.onDamage()` porównywane są całe obiekty wpisów damageMap zamiast ich
wartości `.damage`. `Monster.reward()` wiąże drop z bieżącym targetem.
Dlatego tej ścieżki nie traktujemy jako sprawdzonej reguły wyboru gracza z
największym udziałem. Własne `aggro_target`, killer, lista udziałów i loot_owner
powinny być rozdzielone i mieć jawne reguły. Źródło:
[Monster](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/mob/Monster.ts).

[DropManager](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/manager/DropManager.ts)
łączy kilka źródeł dropu oraz bonusy/level delta. Na spike wystarczy jeden mob,
prosta tabela szans i jedna reguła właściciela. Nie potrzebujemy premium,
empire privileges ani mnożników golda.

[DroppedItem](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/entities/game/item/DroppedItem.ts)
ma prawa właściciela wygasające po 15 s i despawn po 30 s. Czasy są przykładem,
nie proponowanym balansem. W
[PickupItemService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/PickupItemService.ts)
sprawdzane są area, odległość i właściciel. `markTaken()` przed pierwszym await
chroni przed ponownym podniesieniem w tym procesie. Jednak świat i torba są
zmienione przed zapisem DB; ten przepływ nie daje sam z siebie odporności na
awarię zapisu. U nas rezerwacja lootu i commit muszą mieć obsługę błędu.

### Zapis i ekonomia

[ItemManager.flush](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/core/domain/manager/ItemManager.ts)
odtwarza kolejkę po błędzie i nie powinien zgubić update'u dodanego podczas await.
To wartościowy przykład obsługi cache. Promise.all osobnych zapisów nie stanowi
jednak wspólnej transakcji; część rekordów może zostać zapisana przed błędem.

W
[PrivateShopService.buy](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/app/service/PrivateShopService.ts#L288)
jest kontrola konkretnego egzemplarza, miejsca w torbie i limitu waluty. Przedmiot
i gold zmieniają stan w pamięci, a kupujący i sprzedający są zapisywani osobno.
[SaveCharacterService](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/src/game/domain/service/SaveCharacterService.ts)
zwraca wyniki Promise.allSettled; buy nie sprawdza odrzuconych wyników przed OK.
To konkretna granica wzorca: nie używamy go jako gotowej bezpiecznej transakcji
ekonomii. W spike upgrade/reroll zapisuje zmianę instancji oraz zużycie kosztu
w jednej transakcji SQLite i potwierdza sukces po commicie. Handel dwóch graczy
pozostaje późniejszym etapem.

## Co robimy z pozostałymi zależnościami TinyMMO

| Zależność | Rekomendacja po analizie |
| --- | --- |
| Login, auth, gateway, master, world lifecycle | Zachować i sprawdzać przez rzeczywiste logowanie dwóch klientów. Open-MT2 ma inny stos/protokół, nie zastępuje tego fundamentu. |
| ContentRegistryHub i statyczne Resources | Zachować rolę rejestru definicji; przebudować definicje gameplayowe. Nie przechowywać w Resource stanu egzemplarza. |
| Inventory, equipment, item.equip i zapis JSON | Przebudować razem do UID egzemplarzy; przejrzeć wszystkich odbiorców starego `item_id` przed usuwaniem adapterów. |
| Character/LocalPlayer, fizyka, hitboxy, sceny broni i mapy | Zastępować małymi pionowymi etapami przez 3D. Zachować potrzebne interfejsy sesji/replikacji. |
| RewardService i loot | Rozdzielić XP, udział w zabójstwie, losowanie itemów i GroundLoot/Pickup. |
| Party, guild, trade, shops, quests, dungeon, events | Pozostają w kwarantannie poza ścieżką spike'a. Obecność odpowiednika w Open-MT2 nie jest powodem ich uruchamiania. |
| Metinowe pakiety, Node/MySQL/Redis, dane i assets Open-MT2 | Nie dodawać do runtime projektu. Implementujemy własne reguły w Godot. |

Obecny stan usunięć i testów forka jest w [repository-cleanup.md](repository-cleanup.md).
Analiza nie usuwa automatycznie kolejnych modułów ani nie zmienia istniejącego save'a.

## Kolejność implementacji

1. **Minimalny świat 3D i dwie sesje:** mapa Spike, CharacterBody3D, kamera,
   serwerowy ruch, replikacja i reconnect. Potwierdzić realne wejście dwóch klientów.
2. **Pionowa ścieżka itemu:** ItemDefinition/ItemInstance, UID, nowy equip,
   snapshot inventory i zapis/odczyt. Dwa miecze jednej definicji zachowują różne
   bonusy i tożsamość po equipie oraz ponownym logowaniu.
3. **Jeden mob PvE:** AttackRequest, walidacja, HP, idle/chase/attack/return,
   śmierć i pojedyncze przyznanie nagrody.
4. **Loot na ziemi:** drop table, encja 3D, prawo podniesienia, dystans,
   pełna torba i dwa konkurujące żądania pickup.
5. **Upgrade +1 i reroll:** koszty, wynik serwera, zmiana tej samej instancji,
   atomowy zapis i idempotencja ponowionego żądania. Pełne +0…+9 po tej walidacji.

Ta kolejność jest rekomendacją implementacji zgodną z planem spike'a; analiza
nie oznacza, że którykolwiek z nowych etapów został już wykonany.

## Scenariusze weryfikacji do wykorzystania

W repo Open-MT2 przeczytano wybrane testy jako przykłady przypadków brzegowych:
[PickupItemService.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/game/app/service/PickupItemService.test.ts),
[PlayerAttackThrottle.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/core/domain/entities/game/player/PlayerAttackThrottle.test.ts),
[ItemManagerFlush.test](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/test/unit/core/domain/manager/ItemManagerFlush.test.ts).
Nie były uruchamiane w tej analizie.

Nasze kryteria spike'a: atak poza zasięgiem i w innej instancji jest odrzucony;
spam nie zwiększa liczby legalnych akcji; przedmiot można podnieść tylko raz;
pełna torba nie kasuje lootu; nie można wyposażyć cudzego UID; różne egzemplarze
tej samej definicji nie zamieniają bonusów; relog zachowuje equip/upgrade/affixes;
błąd zapisu upgrade/reroll nie zużywa kosztu bez odpowiadającej zmiany itemu;
ponowienie żądania nie nalicza drugi raz kosztu ani nagrody.

## Pochodzenie materiałów

Źródła referencyjne przechowano lokalnie w ignorowanym
`.godot/reference/open-mt2`; nie są częścią kodu naszego forka. Do projektu
dodano tę analizę, bez kopiowania implementacji lub assetów Open-MT2.

[LICENSE](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/LICENSE)
zawiera GPL v3, a README wskazuje GPL. Jednocześnie
[package.json](https://github.com/willianmarquess/open-mt2/blob/8d8800d470f0b69221886723eb5877a2ed9d9d8d/package.json)
ma `license: ISC`. To niespójność metadanych źródła; analiza nie rozstrzyga jej
prawnie. Aktualny sposób użycia to odniesienie do reguł i własna implementacja.
