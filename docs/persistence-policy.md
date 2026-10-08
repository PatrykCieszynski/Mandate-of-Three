# Persistence policy — jawny podział stanu

Przyjęte po review użytkownika. Baza jest warstwą persistence; aktywna postać
ma authoritative state w pamięci World Servera. Nie budujemy ogólnego frameworka
statów, eventów ani autosave całego profilu dla każdej zmiany.

| Stan / operacja | Runtime | Persistence |
| --- | --- | --- |
| XP, level, wolne punkty atrybutów | PlayerResource + osobny dirty set | Checkpoint około 60 s, tylko dirty postacie, jedna transakcja |
| Equipment i combat stats | Minimalny cache serwera, odtworzony przy wejściu | Item transaction od razu, odświeżenie cache po commit |
| ItemInstance: pickup, equip/unequip, własność, placement | Serwer waliduje intencję | Natychmiastowy atomowy zapis |
| Yang z grindu | Balance + pending delta + wallet dirty | Delta checkpoint około 30 s |
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

## Yang: działający wallet i ground currency

W Spike 3D działa oddzielny wallet Yang oraz runtime GroundCurrency. Pies
pozostawia 30 Yang z tymi samymi loot rights co jego item. Waluta jest
automatycznie podnoszona w promieniu 1,25 m; G pozwala podnieść ją do 2,5 m.
Nie ma peta, trwałego UID stosu ani per-drop rekordu DB. Legacy gold pozostaje
oddzielnym upstreamowym stanem i nie jest migrowane do nowego walleta.

Wallet ma jawne `wallet_balance`, `pending_currency_delta` i osobny dirty set.
Przychód zmienia balance w RAM, sumuje dodatnią deltę i oznacza wallet jako dirty.
Checkpoint co 30 s zapisuje sumę delty, zamiast nadpisywać stary snapshot:

```sql
UPDATE wallets SET yang = yang + ? WHERE character_id = ?;
```

Po udanym commit pending delta jest zerowana. Po błędzie pozostaje w RAM do
ponowienia. WorldDatabase ma osobny `dirty_wallet` i checkpoint co 30 s;
nie jest częścią pełnego autosave PlayerResource ani dirty progression.

Testowy przycisk wydaje stałe, serwerowe 50 Yang. Krytyczny wydatek
sprawdza dostępne środki względem runtime balance. Transakcja
obejmuje pending income i odjęcie kosztu. Obecny testowy wydatek tylko zużywa
walutę. Przyszły upgrade/zakup/trade musi zmienić też trwały stan ekonomii
w tej samej transakcji; nie wolno wywołać osobnego spend i osobnego item commit.
Przykład:
DB 40000 + pending 30000 − koszt 50000 = 20000, wszystko w jednym COMMIT.
Po commit runtime balance wynosi 20000 i pending delta 0. Rollback nie zużywa
pending income ani nie publikuje zmiany itemu. Transakcja musi również chronić
przed ujemnym saldem. Stary stan DB nie służy do odrzucania zakupu, na który
po uwzględnieniu pending income gracza stać.

GroundCurrency jest runtime entity: amount, loot rights/owner, position, expiry.
Pickup dodaje kwotę do walleta i usuwa entity. Nie tworzy persistent ItemInstance,
durable UID ani wiersza DB na każdy mały stos Yang. Waluta będąca handlowalnym
przedmiotem w torbie pozostaje jednak itemem/stackiem z immediate persistence.

Wallet i progression mają osobne dirty sety oraz niezależne checkpointy.
Position dirty pozostaje do przyszłego wdrożenia. Wallet jest ładowany przy
wejściu, a logout/disconnect/handoff/save/shutdown wymusza oba checkpointy.
Nieudany zapis walleta zatrzymuje jego RAM oraz pending delta, również offline.
Schema v14 dodaje osobną tabelę `wallets`; serializer PlayerResource jej nie
nadpisuje. Po crashu niezapisany dochód i ground currency mogą zniknąć,
normalnie z okna około 30 s. Zatwierdzony critical spend pozostaje trwały.

## Testy

`run-progression` sprawdza runtime attack po equip, rollback bez zmiany cache,
zero odczytów inventory w obu testowanych zamachach i odtworzenie statów przy
wejściu z utrwalonym equipem. `run-xp` sprawdza wiele killów w RAM, brak tabeli
receiptów, checkpoint, prawdziwy disconnect, rollback całego batcha, wąskie
UPDATE tylko trzech kolumn, brak zapisu clean postaci i zaakceptowane crash window.
Pełne gateway/master/world nadal testuje logout/relog, awans i dokładny UID broni.

`run-yang.ps1` sprawdza delta checkpoint, brak zapisów XP/profile przy Yang,
rollback spend i batcha, prywatny HUD, rights/autoloot/pickup race, expiry,
przeszkody, RPC replay oraz realny disconnect. Pełny `pve_session` sprawdza
Yang zdobyte przez combat i autoloot oraz dokładne saldo po logout/relog.
