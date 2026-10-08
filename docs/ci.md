# CI Mandate

Usunięto odziedziczone build-templates.yml, release.yml i ci/custom.py.
Publikacja Ekonia na itch.io, podpisywanie Androida i kompilacja slim templates
nie należą do aktualnego workflow Mandate. Stary profil wyłączał 3D i nawigację.

verify.yml sprawdza czysty checkout na Windows z Godot 4.7.2 oraz Python 3.12:
placeholdery bez dev_assets, staging i istniejące testy gameplayu, wykonywane
kolejno. Nie uruchamia konwersji Metina, nie pobiera źródeł ani assetów legacy,
nie eksportuje i nie publikuje gry. Logi zostają jako artefakt diagnostyczny.

Export presets i export plugin Tiny MMO zostają: są używane lokalnie i nadal
wykluczają dev_assets oraz generują stuby serwera przy eksporcie klienta.
Przyszły release Mandate będzie osobną, świadomą zmianą z własnym celem publikacji.
