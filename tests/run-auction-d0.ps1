param([string]$GodotExecutable = '', [string]$MainPack = '', [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,50}$')][string]$Label = 'windows-debug', [string]$ExpectedLibrary = 'libgdsqlite.windows.template_debug.x86_64.dll')
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (!$GodotExecutable) { $GodotExecutable = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe' }
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskDirectory = Join-Path $taskLogs ('auction-d0-' + $Label)
New-Item -ItemType Directory -Force -Path $taskDirectory | Out-Null
$taskOut = Join-Path $taskLogs ('auction-d0-' + $Label + '.out.log')
$taskErr = Join-Path $taskLogs ('auction-d0-' + $Label + '.err.log')
$taskPreviousAppData = $env:APPDATA
$taskProcess = $null
try {
    $env:APPDATA = Join-Path $taskDirectory 'appdata'
    $taskArguments = '--headless --path "' + $taskRoot + '" '
    if ($MainPack) { $taskArguments += '--main-pack "' + $MainPack + '" ' }
    $taskArguments += '--mode=world-server res://tests/auction_sqlite_threads.tscn --d0-project-root="' + $taskRoot + '" --d0-directory="' + $taskDirectory + '"'
    $taskProcess = Start-Process -FilePath $GodotExecutable -ArgumentList $taskArguments -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    # Observe the actually loaded library, including the console launcher's child.
    $taskLibrary = ''
    $taskDeadline = (Get-Date).AddSeconds(8)
    while (!$taskLibrary -and (Get-Date) -lt $taskDeadline -and !$taskProcess.HasExited) {
        $taskCandidates = @($taskProcess.Id) + @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $taskProcess.Id -and $_.Name -like 'Godot*' } | Select-Object -ExpandProperty ProcessId)
        foreach ($taskId in $taskCandidates) {
            $taskModules = @((Get-Process -Id $taskId -ErrorAction SilentlyContinue).Modules | Where-Object { $_.ModuleName -eq $ExpectedLibrary })
            if ($taskModules.Count) { $taskLibrary = $taskModules[0].FileName; break }
        }
        if (!$taskLibrary) { Start-Sleep -Milliseconds 100 }
    }
    if (!$taskProcess.WaitForExit(60000)) { throw 'D0 timeout; only this disposable fixture will be terminated' }
    $taskProcess.Refresh()
    $taskOutput = (Get-Content -LiteralPath $taskOut -Raw) + (Get-Content -LiteralPath $taskErr -Raw)
    if (!$taskLibrary -or $taskProcess.ExitCode -ne 0 -or $taskOutput -notmatch 'AUCTION_D0_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error|Caller thread|database is locked|database table is locked|Object is being used by another thread') {
        throw "D0 failed ($Label): $taskOut / $taskErr"
    }
    Write-Output "AUCTION_D0_LIBRARY $taskLibrary SHA256=$((Get-FileHash -LiteralPath $taskLibrary -Algorithm SHA256).Hash)"
    Get-Content -LiteralPath $taskOut | Where-Object { $_ -match 'AUCTION_D0_PLUGIN|AUCTION_D0_CONCURRENCY|AUCTION_D0_OK' }
    Write-Output "Auction D0 ($Label): PASS"
} finally {
    if ($taskProcess -and !$taskProcess.HasExited) { $taskProcess.Kill(); $taskProcess.WaitForExit() }
    $env:APPDATA = $taskPreviousAppData
}
