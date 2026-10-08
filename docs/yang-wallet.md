# Yang wallet — pierwszy slice

Pies po śmierci zostawia item oraz osobne 30 Yang. Wartość jest placeholderem.
GroundCurrency ma wyłącznie lokalny ID encji, kwotę, pozycję, loot rights
największego contributor’a, rezerwację 15 s i lifetime 120 s. Nie zapisuje się
jako ItemInstance ani ground claim w SQLite. Powtórzony callback śmierci nie
tworzy drugiej nagrody.

Auto-pickup działa na serwerze co 0,2 s w promieniu 1,25 m. G podnosi najbliższe
Yang w promieniu 2,5 m. Oba sprawdzają życie gracza, odległość, line of sight,
rezerwację i expiry; klient nie podaje kwoty ani ownership. Publiczny stack
może zostać podniesiony tylko raz. Pełne inventory nie blokuje walleta.
Nie ma jeszcze peta ani konfiguracji auto-pickupu.

WorldDatabase trzyma `runtime_wallets` według persistent character ID:
`wallet_balance`, `pending_currency_delta` i oddzielny `dirty_wallet` set.
Income jest synchroniczną zmianą RAM i usunięciem stosu z ziemi, bez SQL.
HUD dostaje jedynie własne saldo i publiczny stan stosów, bez cudzych walletów.

Co 30 s wszystkie dirty delty zapisują się w jednej transakcji do `wallets`
(schema v14). UPDATE dodaje deltę do istniejącego salda. Commit zeruje pending
oraz dirty; rollback zachowuje je do ponowienia. Clean interval nie otwiera
transakcji. Zapis nie dotyka PlayerResource, inventory ani progression.
Logout/disconnect, opuszczenie mapy, transfer instancji i graceful save/shutdown
wymuszają zapis. Failed offline state jest zachowane i używane przy reentry.
Nowa postać zaczyna z 0 Yang; legacy gold nie jest przenoszone.

## Testowy critical spend

Przycisk „Test: wydaj 50 Yang” zużywa stałe 50 Yang ustalone przez serwer.
To tymczasowa operacja do weryfikacji persistence, bez nagrody za wydatek.
RPC przyjmuje tylko sequence; waliduje sesję, życie, replay i rate limit.
Affordability korzysta z RAM. W jednej transakcji store dodaje pending income
oraz odejmuje koszt z warunkiem nieujemnego salda. Runtime zmienia się dopiero
po commit, a rollback pozostawia balance i pending income bez zmian.

Test SQLite sprawdza `40000 DB + 30000 pending - 50000 spend = 20000` oraz
wymuszony błąd w drugim UPDATE, po dodaniu pending income: całość się wycofuje.
Przyszły upgrade musi dołączyć zużycie materiału i mutację itemu do tego samego
commitu. Ten slice nie tworzy callbacków ani generic transaction frameworka.

Przy crashu akceptujemy utratę niezapisanego income od ostatniego udanego
checkpointu (normalnie około 30 s) oraz runtime ground currency. Zatwierdzony
wydatek i immediate item transactions są trwałe.

## Weryfikacja

`& .\tests\run-yang.ps1`: prawdziwy SQLite i dwa RPC klienty, autoloot,
rights, range/obstruction, expiry/death, pickup race, prywatne saldo/HUD,
critical spend/replay, delta checkpoint, batch rollback i realny disconnect.
`-Preview` zapisuje `.godot/verification/yang-preview.png`.

`tests/pve_session.tscn` przez normalne gateway/master/world sprawdza combat,
item pickup/equip, XP/level oraz Yang autoloot i dokładne saldo po logout/relog.
Yang network współdzieli port 18098 z PvE/combat/progression/XP — uruchamiać
kolejno. Zasady wszystkich kategorii: [Persistence policy](persistence-policy.md).
