# TinyMMO editor integration (legacy name)

This addon remains **enabled** in `project.godot` and must not be removed without replacing its export behavior.

## Current responsibilities

- **Client export:** `export_plugin/export_plugin.gd` excludes server-only resources and substitutes server GDScript classes with generated stubs. It also includes raw optional CEF UI raster assets and a material icon needed by FileAccess.
- **Editor content panel:** `main_screen/main_panel.gd` offers content-index generation, preview and refresh.

The former, disconnected editor inspector extension and its property editor/popup tree have been removed, but the TinyNodePath helper was restored: the live state synchronizer requires it. The old commented plugin bootstrap has also been removed. The package name reflects project ancestry, not a runtime TinyMMO dependency by itself.

## Before removing the addon

Relocate and test its client export hooks, then verify exported client startup, server startup and all references to generated server-class stubs. Removing the editor plugin registration without migration can break packaged builds despite editor/headless tests passing. Do not change the configured user-data directory as part of cleanup: this can affect existing local saves and databases.
