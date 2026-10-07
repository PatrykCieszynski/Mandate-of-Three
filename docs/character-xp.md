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

WorldSchema v12 dodaje `kill_xp_rewards`: UID zabójstwa, trwałe ID właściciela
i ilość XP. UID jest generowany na serwerze i odpowiada UID ground lootu tej
śmierci. Odrodzenie psa rozpoczyna nowe zabójstwo z nowym UID.

Potwierdzenie nagrody oraz UPDATE pól level/experience/available_attributes_points
w `players` są jedną transakcją SQLite. Powtórzony UID jest odrzucany również
po ponownym otwarciu bazy. Zapis nie nadpisuje ekwipunku, profilu ani innych
pól postaci. Cache aktywnej sesji jest aktualizowany po udanym COMMIT, żeby
autosave i disconnect nie cofnęły XP. Właściciel może też otrzymać zapis nagrody
po odłączeniu, jeśli jego postać nadal istnieje w bazie.

Po błędzie zapisu serwer zachowuje oczekującą nagrodę i próbuje ponownie co
sekundę. Ta kolejka jest runtime: zamknięcie instancji przed udanym COMMIT może
utracić oczekującą nagrodę. Już zatwierdzone XP i potwierdzenia są trwałe.
Niepodniesiony loot nadal jest runtime; zapis XP nie zależy od jego claimu.

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
odrzucenie powtórzonego UID, rollback receiptu i XP przy błędzie UPDATE, ponowienie
zapisu, awans 1 → 2 z nadmiarem 10 XP, prywatność postępu, publiczny poziom,
HUD, brak dodatkowego XP za pickup oraz trwałość po legacy save i reopen.
Markery: `XP_SERVER_OK` i dwa `XP_CLIENT_OK`.

Pełne gateway/master/world w `tests/pve_session.tscn` potwierdza identyczne XP
i poziom po relogu razem z podniesionym i założonym ItemInstance. Wariant z flagą
`--xp-levelup` walczy do poziomu 2 i potwierdza zachowanie awansu po relogu.
Regresje itemów,
PvE, combatu, progression i ruchu także przeszły. Render `character-xp-preview.png`
w `.godot/verification` został wygenerowany i obejrzany.

Test rollbacku celowo wywołuje błąd SQL. W logach pozostają wcześniejsze komunikaty
silnika o certyfikatach i zasobach przy zamykaniu. Ręczny test użytkownika tego
etapu pozostaje otwarty.
