# CI Mandate

Usunięto odziedziczone build-templates.yml, release.yml i ci/custom.py.
Publikacja Ekonia na itch.io, podpisywanie Androida i kompilacja slim templates
nie należą do aktualnego workflow Mandate. Stary profil wyłączał 3D i nawigację.

verify.yml sprawdza czysty checkout na Windows z Godot 4.7.2 oraz Python 3.12:
placeholdery bez dev_assets, staging i istniejące testy gameplayu, wykonywane
kolejno. Nie uruchamia konwersji legacy assets, nie pobiera źródeł ani assetów legacy,
nie eksportuje i nie publikuje gry. Logi zostają jako artefakt diagnostyczny.

Export presets i export plugin Tiny MMO zostają: są używane lokalnie i nadal
wykluczają dev_assets oraz generują stuby serwera przy eksporcie klienta.
Przyszły release Mandate będzie osobną, świadomą zmianą z własnym celem publikacji.

Weryfikacja ma osobne kroki: staging Python, legacy pipeline fixtures,
Godot visual fallbacks i gameplay regression suites. Python nadal ma wersję
3.12, a runner windows-latest. Setup Python v7 i upload-artifact v6 używają
aktualnego runtime Actions. Log artifact ma include-hidden-files: true;
zbiera wyłącznie pliki .log, także przy wcześniejszym niepowodzeniu.

Testy stagingu porównują tożsamość plików (os.path.samefile), niezależnie od
Windows 8.3 aliasów katalogu użytkownika. Regresja sprawdza alias tego samego
pliku oraz odrzucenie dodatkowego lub innego pliku. Zabezpieczenia stagingu
przed traversal, zewnętrznym write i symlink/junction pozostają niezmienione.
