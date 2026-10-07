# Persistence policy — jawny podział stanu

Przyjęte po review użytkownika. Baza jest warstwą persistence; aktywna postać
ma authoritative state w pamięci World Servera. Nie budujemy ogólnego frameworka
statów, eventów ani autosave całego profilu dla każdej zmiany.

| Stan / operacja | Runtime | Persistence |
| --- | --- | --- |
| XP, level, wolne punkty atrybutów | PlayerResource + osobny dirty set | Checkpoint około 60 s, tylko dirty postacie, jedna transakcja |
| Equipment i combat stats | Minimalny cache serwera, odtworzony przy wejściu | Item transaction od razu, odświeżenie cache po commit |
| ItemInstance: pickup, equip/unequip, własność, placement | Serwer waliduje intencję | Natychmiastowy atomowy zapis |
| Yang z grindu — przyszły wallet | Balance + pending delta + wallet dirty | Delta checkpoint około 30–60 s |
| Ekonomicznie istotny wydatek Yang | Sprawdzenie możliwości zapłaty względem RAM | Natychmiastowa transakcja obejmująca pending income, wydatek i zmianę ekonomii |
| Trade, upgrade, socket, reroll, crafting | Serwerowy wynik | Natychmiastowa transakcja wszystkich zmienianych trwałych danych |
| Materiały / waluty działające jak inventory item lub stack | Item/stack | Natychmiastowa transakcja, także split/merge i create/destroy |

## Działający obecnie runtime i checkpoint

`WorldServer.runtime_equipment` przechowuje equipment UID i wynikowe statystyki
aktywnej postaci według trwałego ID. Wejście ładuje inventory z SQLite;
`SpikeInventory3D._send_state()` odświeża ten runtime po odczycie zatwierdzonego
stanu. Combat pobiera `attack` z runtime, bez query przy zamachu. Nieudany equip
nie zmienia placement ani ataku; brak poprawnego snapshotu unieważnia cache,
więc combat nie korzysta ze starych statystyk po błędzie odczytu.

Śmierć moba jest zdarzeniem runtime. Stan `DEAD` zabezpiecza przed powtórzeniem
tej samej śmierci w aktualnym encounterze. Rozstrzygnięcie wkładu i XP działa
w RAM; level-up oraz informacja dla klienta są natychmiastowe. Nie ma persistent
KillEvent ani kill ID dla persistence XP. UID ground itemu nadal służy jego
economy-critical claimowi, niezależnie od progression.

`WorldDatabase.dirty_progression` jest osobnym setem referencji do postaci.
Checkpoint co 60 s zapisuje wyłącznie `level`, `experience`,
`available_attributes_points`, w jednej transakcji dla dirty postaci. Sukces
usuwa ich dirty flags, błąd wycofuje całość i pozostawia RAM oraz dirty state do
ponowienia. Brak dirty postaci oznacza brak transakcji. Czytanie postaci podczas
reentry korzysta z dirty resource, aby nie cofnąć niezapisanej progresji.

Wymuszony checkpoint działa przed końcem sesji, przy disconnect i opuszczeniu
mapy 3D, przed istniejącym instance transfer oraz w save/shutdown/restart świata.
Graceful shutdown przez master jest anulowany, gdy checkpoint się nie powiedzie.
Dirty referencja pozostaje dostępna do ponowienia również po disconnect.
Nie ma jeszcze transferu procesu dla 3D; przyszły taki handoff musi czekać na
udany checkpoint przed przekazaniem ownership.

Starszy pełny serializer profilu nadal obsługuje niezależne dane legacy,
zwykły zapis sesji i backup. XP tick ani kill go nie uruchamiają. Jego istniejący
harmonogram nie zastępuje nowego checkpointu progression.

Schema v13 usuwa nieużywaną tabelę `kill_xp_rewards`, zachowując pola XP i itemy.
Po crashu akceptujemy utratę soft progression od ostatniego udanego checkpointu:
normalnie około minuty, a przy niedostępnej bazie do ostatniego udanego zapisu.
Nie odtwarzamy zabójstw z durable historii. Item pickup i placement nadal mają
natychmiastowe transakcje oraz własną ochronę przed double pickup.

## Yang: kontrakt dla przyszłego walleta

W obecnym Spike 3D nie ma jeszcze walleta Yang, GroundCurrency ani autolootu.
Ten refactor zapisuje ich politykę; nie uruchamia nowego systemu waluty ani
nie przenosi legacy gold z inventory do walleta.

Wallet ma mieć jawne `wallet_balance`, `pending_currency_delta`, `wallet_dirty`.
Przychód zmienia balance w RAM, sumuje dodatnią deltę i oznacza wallet jako dirty.
Checkpoint zapisuje sumę delty, zamiast nadpisywać stary snapshot:

```sql
UPDATE wallet SET yang = yang + ? WHERE character_id = ?;
```

Po udanym commit pending delta jest zerowana. Po błędzie pozostaje w RAM do
ponowienia. Wallet ma osobną kategorię dirty i checkpoint około 30–60 s;
nie jest częścią pełnego autosave PlayerResource ani dirty progression.

Krytyczny wydatek sprawdza dostępne środki względem runtime balance. Transakcja
obejmuje pending income, odjęcie kosztu i zmianę itemu/zakupu/trade. Przykład:
DB 40000 + pending 30000 − koszt 50000 = 20000, wszystko w jednym COMMIT.
Po commit runtime balance wynosi 20000 i pending delta 0. Rollback nie zużywa
pending income ani nie publikuje zmiany itemu. Transakcja musi również chronić
przed ujemnym saldem. Stary stan DB nie służy do odrzucania zakupu, na który
po uwzględnieniu pending income gracza stać.

GroundCurrency jest runtime entity: amount, loot rights/owner, position, expiry.
Pickup dodaje kwotę do walleta i usuwa entity. Nie tworzy persistent ItemInstance,
durable UID ani wiersza DB na każdy mały stos Yang. Waluta będąca handlowalnym
przedmiotem w torbie pozostaje jednak itemem/stackiem z immediate persistence.

Position, wallet i progression mają mieć osobne dirty categories, kiedy są
wdrażane. Obecnie istnieje wyłącznie potrzebny dirty progression; nie dodajemy
pustych kategorii ani niewykorzystywanych klas na przyszłość.

## Testy

`run-progression` sprawdza runtime attack po equip, rollback bez zmiany cache,
zero odczytów inventory w obu testowanych zamachach i odtworzenie statów przy
wejściu z utrwalonym equipem. `run-xp` sprawdza wiele killów w RAM, brak tabeli
receiptów, checkpoint, prawdziwy disconnect, rollback całego batcha, wąskie
UPDATE tylko trzech kolumn, brak zapisu clean postaci i zaakceptowane crash window.
Pełne gateway/master/world nadal testuje logout/relog, awans i dokładny UID broni.
