# XP i poziomy postaci — Spike 3D

Stan: 2026-10-07, branch `codex/character-xp`. Serwerowe XP po śmierci Wild Doga,
level-up, HUD i trwałość po relogu. Parametry walki i itemów pozostają bez zmian.

## Nagroda i poziomy

Wild Dog daje 20 XP. Całą nagrodę otrzymuje właściciel największego udziału
w faktycznie zadanych obrażeniach, tak jak przy rezerwacji łupu. Overkill nie
zwiększa udziału; remis rozstrzyga niższe trwałe ID postaci. Ostatni cios nie
przejmuje automatycznie nagrody. XP przysługuje za śmierć moba, niezależnie od
podniesienia itemu; same trafienia i pickup nie dodają doświadczenia.

Wykorzystujemy istniejące `PlayerResource.add_experience()` i krzywą
`70 × aktualny poziom`. Nadmiar XP przechodzi na kolejny poziom. Cztery psy
od zera dają 80 XP: poziom 2 i 10/140 XP. To parametry prototypu, do późniejszego
balansu. Istniejący zapis wolnych punktów atrybutów zachowuje przyrost +3 za level;
rozdawanie punktów nie jest dostępne w tym 3D i nie zmienia ataku ani HP.

HUD pokazuje poziom, XP do następnego poziomu, pasek postępu i przez 5 sekund
komunikat nagrody/awansu. Nazwa gracza nad kapsułą zawiera poziom. Poziomy są
publiczne, dokładny postęp XP trafia tylko do właściciela. Klient nie wysyła
polecenia przyznania XP, ilości doświadczenia ani oczekiwanego poziomu.

## Zapis i idempotencja

XP i level zmieniają się natychmiast w authoritative PlayerResource w RAM.
WorldDatabase oznacza progression postaci jako dirty i zapisuje te postacie
co około 60 s, w jednej transakcji obejmującej tylko level, experience i wolne
punkty atrybutów. Disconnect/logout, transfer i graceful shutdown wymuszają zapis.
Niepodniesiony loot nadal jest runtime; checkpoint XP nie zależy od jego claimu.

WorldSchema v13 usuwa wcześniejsze `kill_xp_rewards`. Nie zapisujemy historii
zabójstw ani nie tworzymy trwałego kill ID. Stan DEAD moba zapobiega powtórzeniu
tej samej śmierci w pojedynczym authoritative World Serverze. Po crashu akceptujemy
utratę soft progression od ostatniego checkpointu. Szczegóły i rozdzielenie itemów,
XP oraz przyszłego walleta opisuje [persistence policy](persistence-policy.md).

## Weryfikacja

```powershell
& .\tests\run-xp.ps1
& .\tests\run-xp.ps1 -Preview
```

Serwer i dwa klienty używają izolowanej SQLite i portu 18098. Uruchamiaj kolejno
z testami PvE, combat i item progression. Fixture zmniejsza HP psów, żeby skrócić
test; nie zmienia kodu produkcyjnego ataku ani przyznawania XP.

Potwierdzono największy udział zamiast ostatniego ciosu, rzeczywiste obrażenia
z uwzględnieniem overkill, brak XP przed śmiercią, podwójny callback śmierci,
wiele killów bez zapisu XP do DB, awans 1 → 2 z nadmiarem 10 XP, prywatność
postępu, publiczny poziom, HUD, brak dodatkowego XP za pickup, checkpoint/reopen
oraz prawdziwy disconnect z dirty progression. Test checkpointów sprawdza batch,
rollback, wąskie UPDATE, forced save i zaakceptowane crash window bez receiptów.
Markery: `CHECKPOINT_OK`, `XP_SERVER_OK` i dwa `XP_CLIENT_OK`.

Pełne gateway/master/world w `tests/pve_session.tscn` potwierdza identyczne XP
i poziom po relogu razem z podniesionym i założonym ItemInstance. Wariant z flagą
`--xp-levelup` walczy do poziomu 2 i potwierdza zachowanie awansu po relogu.
Regresje itemów,
PvE, combatu, progression i ruchu także przeszły. Render `character-xp-preview.png`
w `.godot/verification` został wygenerowany i obejrzany.

Test checkpointu celowo wywołuje błąd SQL. W logach pozostają wcześniejsze komunikaty
silnika o certyfikatach i zasobach przy zamykaniu. Ręczny test użytkownika tego
etapu pozostaje otwarty.
