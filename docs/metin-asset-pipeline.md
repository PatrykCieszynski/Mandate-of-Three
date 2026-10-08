# Lokalny pipeline konwersji Metin2

Pipeline jest narzędziem developerskim. Legacy źródła, zależności importera,
cache, logi, modele i tekstury zostają poza projektem Godot i Git. Konwersja nie
wykonuje stagingu. Gameplay nadal korzysta z logicznych visual IDs, a AI, ruch,
walka, economy i persistence nie wybierają zachowania na podstawie grafiki.

## Reuse sprawdzonego spike'a

BlenderGR2rs w rewizji 8722bb1e6fa431cfd395b4e56f8eb2c37b9e05fc i Blender 5.1.2
pozostają sprawdzonym zestawem. Nie ma nowego dekodera GR2 ani pack extractora.
Skrypt blender_export.py przenosi procedury load, materialize i export oraz bind
włosów ze sprawdzonego eksportu Warriora. Zachowuje skalę .01, flip UV V, Z rotation
180° dla aktorów, standardowy glTF Y-up, sampling 30 FPS i siedem mapowań klipów
Warriora. Sword zachowuje bake rest transform do metrów i usunięcie jednego bone.
Wspólny socket dalej obraca ostrze o +90° local Z.

Nową częścią jest orchestration: indeks, ActorBundle, jawny katalog, rozwiązywanie
wygrywających tekstur, fingerprint, osobny proces Blender dla konwersji,
raportowanie i staging. Dotychczasowe pojedyncze eksportery zewnętrznego spike'a
pozostają dostępne jako referencja; stager czterech pierwotnych ID nadal działa.

## Konfiguracja

Python 3.12+ (stdlib), Blender i checkout BlenderGR2rs z jego natywną biblioteką.
Checkout importera musi być zewnętrzny. Narzędzia nie instalują go automatycznie.

Skopiuj tools/metin_assets/local.example.json do gitignored local.json. Ustaw:
source_root (katalog z bin/pack), generated_root, blender, importer_root
(katalog zawierający moduł BlenderGR2rs), importer_revision. generated_root może
być pod source_root/generated, ale nie pod bin ani wewnątrz projektu Godot.
Względne ścieżki konfiguracji są liczone od repo root. Przykład katalogu źródeł:
../Mandate Local/metin2; ten przykład nie jest ścieżką zakodowaną w gameplayu.

Każde pole można nadpisać środowiskiem MANDATE_METIN_SOURCE_ROOT,
MANDATE_METIN_GENERATED_ROOT, MANDATE_METIN_BLENDER, MANDATE_METIN_IMPORTER_ROOT,
MANDATE_METIN_IMPORTER_REVISION. --config pozwala użyć innego pliku konfiguracji.

## Komendy

Uruchom z repo root:

```powershell
python tools/metin_assets/pipeline.py index
python tools/metin_assets/pipeline.py query --race 101
python tools/metin_assets/pipeline.py query --virtual-path 'd:/ymir work/monster/stray_dog/stray_dog.gr2'
python tools/metin_assets/pipeline.py query --category player --name warrior
python tools/metin_assets/pipeline.py query --pack patch1 --limit 10
python tools/metin_assets/pipeline.py resolve_asset stray_dog
python tools/metin_assets/pipeline.py convert_asset stray_dog
python tools/metin_assets/pipeline.py convert_group mobs_m1
python tools/metin_assets/pipeline.py convert_group orcs
python tools/metin_assets/pipeline.py convert_group warrior_male
python tools/metin_assets/pipeline.py convert_group first_batch
python tools/metin_assets/pipeline.py stage_asset stray_dog
python tools/metin_assets/pipeline.py stage_asset warrior_male
python tools/metin_assets/pipeline.py stage_group mobs_m1
```

Pozostałe grupy: metin_stones i basic_swords. first_batch to jawnie wybrane 23
assety, nie cała biblioteka. warrior_male jest aliasem działającego visual ID
warrior; zachowujemy istniejące ścieżki players/warrior zamiast przenosić je do
characters i zmieniać działającą integrację. boar jest aliasem wild_boar.

stage_group z --skip-failed kopiuje tylko udane konwersje i wypisuje pominięte ID
w not_staged. Bez tej opcji błąd stagingu kończy komendę; wcześniejsze poprawne
kopie mogą już istnieć. Staging jest atomowy per GLB, nie cała grupa.

## Indeks i źródła

generated/.pipeline/asset_index.json przechowuje 55,156 plików i 1,336 aktorów
npclist z obecnego lokalnego źródła. Każdy plik ma relative_path, virtual_path,
pack, order, registered, selected, type, category, size, mtime_ns, sha256 oraz
duplicate_group. duplicate_groups zachowuje wszystkie źródła o wspólnym hashu;
deduplikacja nie zmienia wygrywającego providera.

Rejestracja z Index.dev odpowiada rozpakowanym FOLDER providerom. Kolejność jest
odwzorowana z klienta: pack, opcjonalny pack_texcache, następny pack.
FIRST REGISTERED PATH WINS; drugi wpis tej samej nazwy packa jest ignorowany.
Nieobecne providery zostają w provenance, niezarejestrowane foldery są widoczne
w indeksie, ale nie mogą nadpisać zarejestrowanego virtual path. Normalizacja
usuwa drive prefix, zmienia slash/case i zachowuje pełne ymir work/... .

RaceManager search order i aliasy npclist pozwalają znaleźć MSM; jego base model
oraz motlist/MSA wyznaczają model i klipy. Zapisujemy LOD-y i wszystkie motion
warianty z wagami, ale eksportujemy pierwsze podstawowe mapowanie semantyki.
MSM SourceSkin/TargetSkin jest uwzględniane dla prostego ShapeData00. Złożone
shape/costume layouts i # local resource paths nie są objęte obecnymi recipes.
Nie próbujemy odtwarzać motion combat timings, efektów MSE ani collision data.

Tekstury GR2 odczytuje natywne API BlenderGR2rs; globalny indeks wybiera zwycięski
virtual path. Względny basename jest rozwiązywany tylko obok konkretnego modelu,
a nie przez globalne wyszukiwanie pierwszego pasującego pliku. Warriora obsługuje
sprawdzona recipe z włosami i wariantami. Dla obu kamieni wybór DDS jest jawny,
ponieważ ich GR2 nie zawiera diffuse binding. Nie wyciągamy strings z binarnego GR2.

Po dodaniu plików lub zmianie npclist/registracji uruchom index ponownie.
Zmiana Index.dev blokuje konwersję ze starego indeksu. Zmiany istniejących modeli,
MSM, MSA i tekstur są odczytywane przy następnej konwersji; używane dependencies
są ponownie hashowane. Query --sha256 znajduje wszystkie duplikaty/provenance.

## Cache, raporty i błędy

Udany GLB i jego <id>.manifest.json leżą pod generated/mobs, players lub weapons.
Manifest zapisuje source_files z pack/order/hash, timestamp, converter signature,
rewizję importera, wersję Blendera, settings, texture mapping, bone names,
animation mapping, bounds, root displacement i warnings.

Fingerprint obejmuje dependencies, recipe, rejestrację, skrypty pipeline'u,
pliki Python/natywne importera oraz identyfikator lokalnego executable Blendera.
Hash bieżącego outputu zabezpiecza przed zaakceptowaniem uszkodzonego cache.
Udany fingerprint daje SKIPPED; zmiana źródeł/konwertera albo --force rekonwertuje.

Osobne procesy Blendera izolują błędy konwersji. Metadane modeli są cache'owane;
gdy zbiorczy native probe się wywróci, modele są sprawdzane osobno. Logi i ostatnia
próba leżą w generated/.pipeline/jobs/<id>/; report grupy pod .pipeline/reports/.
Report jest aktualizowany po każdym aktorze. Pełen przebieg kontynuuje po błędzie,
ale zwraca exit code 1, jeżeli jakikolwiek asset się nie powiódł.

Statusy: SUCCESS, SKIPPED, MISSING_MODEL, MISSING_TEXTURE, MISSING_ANIMATION,
IMPORT_FAILED, EXPORT_FAILED, INVALID_SKELETON, UNKNOWN_LAYOUT. Brak wymaganej
tekstury/klipu jest błędem, nie cichym białym materiałem. Nieudana próba zachowuje
poprzedni dobry GLB, ale nie aktualizuje successful manifest; stager odrzuca asset
z ostatnią nieudaną próbą. Można go ponowić po poprawce.

GLB zachowuje natywną root translation dla audytu. Godot VisualAnimationTools
kopiuje klipy per instancja i zamraża root X/Z, zachowując pionowy bob i rotację.
Standalone GLB viewer może więc pokazać root motion; w gameplayu aktor nie może
zmieniać authoritative pozycji przez animację. Test obejmuje wszystkie klipy.

## Pierwszy batch i granice

Pierwszy reprezentatywny batch: **23 próby, 21 SUCCESS, 19 assetów z warnings,
2 IMPORT_FAILED**. Ponowny niezmieniony przebieg: 21 SKIPPED i ponowienie 2 błędów.
Wśród 19 warnings są 17 udanych actor bundles (root motion / motion variants)
oraz 2 kamienie z jawną wskazówką tekstury. Nie są to 19 brakujących zależności.

Oba kamienie korzystają z tego samego metinstone_01.gr2. Importer odrzuca go:
file.customization: models: raw/high-level count mismatch (1 != 0).
Native probe widzi 89 meshes i 1 skeleton; dalszy import nie przechodzi walidacji.
Nie obchodzimy jej własnym parserem. Oba logical IDs używają tracked placeholder.
Pełne logi pozostają lokalne, a struktura problemu jest tu zapisana do przyszłego
zgłoszenia/testu nowszej rewizji importera.

GPU gallery potwierdza tekstury, proporcje i spójną orientację 21 modeli oraz dwa
fallbacki. Test Godot ładuje dwie niezależne instancje, wszystkie klipy, sprawdza
materiały/tekstury, skeleton, prywatne animation resources i neutralizację root
motion. Warrior socket i siedem clip states pozostają objęte dotychczasowym
run-warrior. Scale .01 i orientation 180° są sprawdzonym wspólnym ustawieniem;
inne kategorie mogą wymagać osobnej recipe, nie automatycznej korekcji po rozmiarze.

```powershell
python -m unittest discover -s tests -p test_metin_pipeline.py
python -m unittest discover -s tests -p test_asset_staging.py
& ./tests/run-metin-batch.ps1 -Capture
& ./tests/run-visuals.ps1 -WithExport
```

run-metin-batch wymaga lokalnej konfiguracji i gotowego first_batch report.
Tymczasowo stage'uje wyłącznie udane wybrane assety, sprawdza również wyłączone
visuals i fizyczne usunięcie staged tree przy zachowanych import caches, po czym
przywraca całą wcześniejszą zawartość dev_assets/metin2 w finally.
Gallery i wyniki Godot są w gitignored .godot/verification. CI używa wyłącznie
syntetycznych fixtures oraz 23 tracked fallbacków; nie odpala tej lokalnej galerii
ani Blendera. Publiczne eksporty wykluczają dev_assets i oba local.json.
