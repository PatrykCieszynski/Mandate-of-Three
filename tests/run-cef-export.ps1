# Optional packaging boundary check, only when changing addon/export integration.
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
if (-not (Test-Path (Join-Path $taskRoot 'addons/godot_cef/godot_cef.gdextension'))) { throw 'Install CEF with tools/cef_client/setup.py first' }
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($taskPreset in @('Windows','ServerWindows','ServerUbuntu')) {
    $taskPack = Join-Path $taskLogs "$taskPreset.zip"
    $taskLog = Join-Path $taskLogs "$taskPreset.export.log"
    & $taskExe --headless --path $taskRoot --export-pack $taskPreset $taskPack *> $taskLog
    if ($LASTEXITCODE -ne 0) { throw "Export failed: $taskLog" }
    $taskZip = [IO.Compression.ZipFile]::OpenRead($taskPack)
    try {
        $taskNames = @($taskZip.Entries | ForEach-Object { $_.FullName })
        $taskEntry = $taskZip.GetEntry('.godot/extension_list.cfg')
        $taskReader = [IO.StreamReader]::new($taskEntry.Open())
        try { $taskExtensions = $taskReader.ReadToEnd() } finally { $taskReader.Dispose() }
        if ($taskPreset -eq 'Windows') {
            foreach ($taskRequired in @('addons/godot_cef/godot_cef.gdextension','source/client/ui_web/web/inventory/game.html','source/client/ui_web/web/inventory/game.js','source/client/ui_web/web/inventory/inventory.css')) {
                if ($taskRequired -notin $taskNames) { throw "Missing client resource: $taskRequired" }
            }
            if ($taskExtensions -notmatch 'godot_cef') { throw 'Client does not register CEF' }
            $taskSkin = Join-Path $taskRoot 'source/client/ui_web/web/inventory/legacy_skin'
            foreach ($taskImage in Get-ChildItem -LiteralPath $taskSkin -Filter '*.png' -File) {
                if ("source/client/ui_web/web/inventory/legacy_skin/$($taskImage.Name)" -notin $taskNames) { throw "Missing raw CEF image: $($taskImage.Name)" }
            }
        } else {
            if ($taskExtensions -match 'godot_cef' -or @($taskNames | Where-Object { $_ -like 'addons/godot_cef/*' }).Count -ne 0) { throw "CEF leaked into $taskPreset" }
        }
    } finally { $taskZip.Dispose() }
    if ($taskPreset -eq 'ServerWindows') {
        $taskBootLog = Join-Path $taskLogs 'ServerWindows.boot.log'
        & $taskExe --headless --main-pack $taskPack --mode=world-server res://tests/web_ui_bridge.tscn --quit-after 120 *> $taskBootLog
        $taskOutput = Get-Content -LiteralPath $taskBootLog -Raw
        if ($LASTEXITCODE -ne 0 -or $taskOutput -notmatch 'WEB_UI_PROTOCOL_OK' -or $taskOutput -match 'SCRIPT ERROR|Assertion failed|VulkanHook|Initialize godot-rust') { throw "Server pack boot failed: $taskBootLog" }
    }
    Remove-Item -LiteralPath $taskPack -Force
    Write-Output "$taskPreset packaging boundary: PASS"
}
Write-Output 'Pack resources and server boot checked; full native executable/client graphics require release verification.'
