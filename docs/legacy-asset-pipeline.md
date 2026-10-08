# External legacy asset pipeline - historical record

The optional local development pipeline was validated against legacy Metin2
client assets. Metin2 is a third-party game/trademark unaffiliated with this
project. Mandate distributes no original or derived third-party assets.

**Repository status, 2026-10-08:** the owner removed the in-repository converter,
index, catalog and example configuration. Their obsolete fixture/CI step and local
batch runner were removed as well. Commands below record the former tooling;
they no longer run from this repository. Conversion remains external. Existing
GLBs can still be staged with tools/dev_assets/stage_asset.py; see
[local development visuals](local-dev-visuals.md). Generated assets in this
workspace were reported at `N:/Mandate local/metin2/generated`; source locations
belong in ignored local configuration, never in gameplay code.

The remaining sections retain the implementation findings and historical results.

## Development boundary

Legacy sources, importer dependencies, cache, logs, models and textures stay
outside the Godot project/Git. Conversion does not stage assets. Gameplay uses
logical visual IDs; AI, movement, combat, economy and persistence do not select
behavior from artwork.

## Reuse of the validated spike

BlenderGR2rs revision 8722bb1e6fa431cfd395b4e56f8eb2c37b9e05fc and Blender 5.1.2
were the validated combination. No new GR2 decoder or pack extractor was added.
blender_export.py reused Warrior load/materialize/export and hair binding.
It retained scale .01, UV V flip, 180-degree Z rotation for actors, standard glTF
Y-up, 30 FPS sampling and seven Warrior clip mappings. Sword export retained
rest-transform baking into metres and removal of its single bone. The shared
socket still rotates the blade +90 degrees on local Z.

New orchestration covered index, ActorBundle, explicit catalog, winning texture
resolution, fingerprints, separate Blender processes, reporting and staging.
External single-asset spike exporters remained references; the original four-ID
stager remains available in this repository.

## Former configuration

Required Python 3.12+ (stdlib), Blender and an external BlenderGR2rs checkout with
its native library. Tools did not install the importer automatically.

The former tools/legacy_assets/local.example.json was copied to ignored local.json
with source_root (bin/pack parent), generated_root, blender, importer_root
(directory containing BlenderGR2rs) and importer_revision. generated_root could
be source_root/generated but not under bin or inside the Godot project. Relative
paths resolved from repository root. ../Mandate Local/legacy was an example, not
a gameplay constant.

Environment overrides were MANDATE_LEGACY_SOURCE_ROOT,
MANDATE_LEGACY_GENERATED_ROOT, MANDATE_LEGACY_BLENDER, MANDATE_LEGACY_IMPORTER_ROOT
and MANDATE_LEGACY_IMPORTER_REVISION; --config selected another configuration.

| Historical command | Required configuration |
| --- | --- |
| index, query, resolve_asset | source_root, generated_root |
| stage_asset, stage_group | generated_root |
| convert_asset, convert_group, resolve_asset --native | source_root, generated_root, blender, importer_root, importer_revision |

Ordinary resolve_asset read index/text dependencies without native probing.
--native added full GR2 texture resolution via the importer. Conversion always
used full probing. Staging needed no sources/index/Blender/importer.

The earlier naming cleanup moved local config to tools/legacy_assets/local.json
and selected assets to res://dev_assets/legacy/, with MANDATE_LEGACY_ variables
and no old API aliases. External source/generated directory names did not need
changing or reconversion merely for staging names. Tooling changes affected the
converter fingerprint under the existing cache policy.

## Historical commands

These refer to the removed converter and are preserved only as an operational record:

```powershell
python tools/legacy_assets/pipeline.py index
python tools/legacy_assets/pipeline.py query --race 101
python tools/legacy_assets/pipeline.py query --virtual-path 'd:/ymir work/monster/stray_dog/stray_dog.gr2'
python tools/legacy_assets/pipeline.py query --category player --name warrior
python tools/legacy_assets/pipeline.py query --pack patch1 --limit 10
python tools/legacy_assets/pipeline.py resolve_asset stray_dog
python tools/legacy_assets/pipeline.py convert_asset stray_dog
python tools/legacy_assets/pipeline.py convert_group mobs_m1
python tools/legacy_assets/pipeline.py convert_group orcs
python tools/legacy_assets/pipeline.py convert_group warrior_male
python tools/legacy_assets/pipeline.py convert_group first_batch
python tools/legacy_assets/pipeline.py stage_asset stray_dog
python tools/legacy_assets/pipeline.py stage_asset warrior_male
python tools/legacy_assets/pipeline.py stage_group mobs_m1
```

Other groups: reference_stones/basic_swords. first_batch explicitly selected 23
assets, not the entire library. warrior_male aliased the existing warrior visual,
retaining players/warrior rather than moving paths to characters. boar aliased wild_boar.

stage_group --skip-failed copied only successful conversions and reported omitted
IDs in not_staged. Without it, staging errors stopped the command, although earlier
copies could exist. Staging was atomic per GLB, not per group.

## Index and source resolution

The local source index generated/.pipeline/asset_index.json contained 55,156 files
and 1,336 npclist actors. File metadata: relative_path, virtual_path, pack, order,
registered, selected, type, category, size, mtime_ns, sha256 and duplicate_group.
duplicate_groups retained all equal-hash sources; deduplication did not change
winning providers.

Index.dev registration followed unpacked FOLDER providers and client ordering:
pack, optional pack_texcache, next pack. FIRST REGISTERED PATH WINS; repeated pack
names were ignored. Missing providers remained in provenance; unregistered folders
were visible but could not override registered virtual paths. Normalization
removed drive prefixes, normalized slashes/case and retained full ymir work/... paths.

RaceManager search order/npclist aliases resolved MSM; its base model and motlist/
MSA determined models/clips. LODs and weighted motion variants were recorded,
but export selected the first basic semantic mapping. Simple ShapeData00 honored
MSM SourceSkin/TargetSkin. Complex shape/costume layouts and # local resource paths
were outside recipes. Motion combat timings, MSE effects and collision data were
not reconstructed.

BlenderGR2rs native APIs read GR2 textures; the global index chose winning virtual
paths. Relative basenames resolved beside the specific model, never by a global
first-match search. Warrior used its validated hair/variant recipe. Both reference
stones had explicit DDS choices because their GR2 had no diffuse binding.
No binary GR2 string extraction was used.

Adding files or changing npclist/registration required reindexing. Index.dev
changes blocked conversion against a stale index. Existing model/MSM/MSA/texture
changes were read on the next conversion; used dependencies were rehashed.
Query --sha256 found all duplicates/provenance.

## Cache, reports and failures

Successful GLBs and <id>.manifest.json lived under generated/mobs, players or
weapons. Manifests included source_files pack/order/hash, timestamp, converter
signature, importer revision, Blender version, settings, texture mapping, bone
names, animation mapping, bounds, root displacement and warnings.

Fingerprints included dependencies, recipe, registration, pipeline scripts,
importer Python/native files and local Blender executable identity. Output hashes
rejected corrupt cache. Matching successful fingerprints yielded SKIPPED;
source/converter changes or --force reconverted.

Unexpected Python/orchestration errors yielded PIPELINE_ERROR, pipeline_error.log
and last_attempt.json traceback. Other group assets continued, but exit status
was nonzero. Known dependency/importer errors kept domain statuses.

Separate Blender processes isolated conversion failures. Model metadata was cached;
failed aggregate native probes fell back to individual probes. Logs/latest attempts
lived under generated/.pipeline/jobs/<id>/; group reports under .pipeline/reports/.
Reports updated per actor. Full runs continued after failures but exited 1 if any
asset failed.

Statuses: SUCCESS, SKIPPED, MISSING_MODEL, MISSING_TEXTURE, MISSING_ANIMATION,
IMPORT_FAILED, EXPORT_FAILED, INVALID_SKELETON, UNKNOWN_LAYOUT, PIPELINE_ERROR.
Missing required texture/clip was an error rather than a silent white material.
Failed attempts retained the previous good GLB without updating its successful
manifest; staging rejected assets whose latest attempt failed. They could be retried.

GLBs retained native root translation for auditing. Godot VisualAnimationTools
duplicates clips per instance and freezes root X/Z, retaining vertical bob/rotation.
Standalone viewers may therefore show root motion; gameplay animation cannot
change authoritative position. Tests cover every clip.

## First batch and boundaries

Representative first batch: **23 attempts, 21 SUCCESS, 19 assets with warnings,
2 IMPORT_FAILED**. An unchanged rerun gave 21 SKIPPED and retried two failures.
The 19 warnings comprised 17 successful actor bundles (root motion/motion variants)
and two explicit stone texture hints, not 19 missing dependencies.

Both stones used metinstone_01.gr2. Importer validation rejected it:
file.customization: models: raw/high-level count mismatch (1 != 0).
Native probing found 89 meshes and one skeleton; import still failed validation.
No custom-parser bypass was added. Both logical IDs use tracked placeholders.
Full logs remain local; the issue structure is retained for a future report or
new-importer-revision test.

The GPU gallery confirmed textures, proportions and consistent orientation for
21 models plus two fallbacks. Godot loaded two independent instances, every clip,
materials/textures, skeletons, private animation resources and root-motion
neutralization. Existing run-warrior still covers its socket/seven clip states.
Scale .01/orientation 180 degrees were validated shared settings; other categories
may need separate recipes, not size-based automatic correction.

Former verification commands (converter fixture/batch runner are now removed):

```powershell
python -m unittest discover -s tests -p test_legacy_asset_pipeline.py
python -m unittest discover -s tests -p test_asset_staging.py
& ./tests/run-legacy-batch.ps1 -Capture
& ./tests/run-visuals.ps1 -WithExport
```

The former batch runner needed local config and a first_batch report. It temporarily
staged successful selected assets, tested disabled visuals and physical staged-
tree removal with import caches retained, then restored the original
dev_assets/legacy tree in finally. Gallery/results stayed in ignored
.godot/verification. Current CI uses staging fixtures and 23 tracked fallbacks;
it runs neither the removed converter tests nor Blender/local galleries. Public
exports exclude dev_assets and local configuration files.
