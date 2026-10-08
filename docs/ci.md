# Mandate CI

Inherited build-templates.yml, release.yml and ci/custom.py were removed.
Ekonia itch.io publishing, Android signing and slim-template compilation are not
part of Mandate's current workflow. The old profile disabled 3D and navigation.

verify.yml checks a clean Windows checkout with Godot 4.7.2 and Python 3.12:
placeholders without dev_assets, staging and existing sequential gameplay tests.
It does not convert legacy assets, download legacy sources/assets, export or
publish the game. Logs remain diagnostic artifacts.

Tiny MMO export presets/plugin remain for local use. They exclude dev_assets
and generate server stubs when exporting clients. A future Mandate release is a
separate deliberate change with its own publishing target.

Verification has separate Python staging, Godot visual fallback and gameplay
regression steps. The in-repository legacy converter was removed on 2026-10-08;
its obsolete Python fixture and CI step were removed with it. The 23 tracked
fallbacks and their Godot test remain. External conversion is not a CI requirement.

Python remains 3.12 on windows-latest. Setup Python v7 and upload-artifact v6 use
the selected Actions runtime. The log artifact uses include-hidden-files: true
and collects only .log files, including on earlier failure.

Staging tests compare file identity with os.path.samefile independently of Windows
8.3 user-directory aliases. Regression covers aliases of the same file and rejects
extra/different files. Traversal, external-write and symlink/junction protection
remain unchanged.
