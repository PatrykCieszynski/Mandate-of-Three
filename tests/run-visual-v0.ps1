param(
    [ValidateSet('mobile','forward_plus','both')][string]$RenderingMethod = 'both',
    [ValidateSet('visual_v0','visual_v1')][string]$Scene = 'visual_v0'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskExe = Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskLogs = Join-Path $taskRoot '.godot/verification'
$taskCapturePrefix = $Scene.Replace('_','-')
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'addons/godot_cef/godot_cef.gdextension'))) { throw 'Install pinned CEF first: tools/cef_client/setup.py' }
New-Item -ItemType Directory -Path $taskLogs -Force | Out-Null
$taskPreviousAppData = $env:APPDATA
$taskPreviousLocalAppData = $env:LOCALAPPDATA
try {
    $env:APPDATA = Join-Path $taskLogs 'visual-v0-appdata'
    $env:LOCALAPPDATA = Join-Path $taskLogs 'visual-v0-localappdata'
    $taskMethods = if ($RenderingMethod -eq 'both') { @('mobile','forward_plus') } else { @($RenderingMethod) }
    foreach ($taskMethod in $taskMethods) {
        $taskProcesses = @()
        try {
            foreach ($taskRole in @('server','client')) {
                $taskArgs = '--path "' + $taskRoot + '" res://tests/' + $Scene + '.tscn --v0-renderer=' + $taskMethod + ' --visual-prefix=' + $taskCapturePrefix
                if ($taskRole -eq 'server') { $taskArgs += ' --headless --mode=world-server' }
                else { $taskArgs += ' --mode=client --rendering-method ' + $taskMethod + ' --rendering-driver vulkan --resolution 1280x720' }
                $taskPrefix = Join-Path $taskLogs "$taskCapturePrefix-$taskMethod-$taskRole"
                $taskProcess = Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput "$taskPrefix.out.log" -RedirectStandardError "$taskPrefix.err.log"
                $taskProcesses += [pscustomobject]@{ Role=$taskRole; Process=$taskProcess; Prefix=$taskPrefix }
                if ($taskRole -eq 'server') { Start-Sleep -Seconds 1 }
            }
            foreach ($taskEntry in ($taskProcesses | Sort-Object Role)) {
                if (-not $taskEntry.Process.WaitForExit(85000)) { throw "Timeout: $taskMethod $($taskEntry.Role)" }
                $taskEntry.Process.Refresh()
                $taskOutput = Get-Content -LiteralPath "$($taskEntry.Prefix).out.log" -Raw
                $taskErrors = Get-Content -LiteralPath "$($taskEntry.Prefix).err.log" -Raw
                $taskMarker = if ($taskEntry.Role -eq 'server') { 'VISUAL_V0_SERVER_OK' } else { 'VISUAL_V0_CLIENT_OK' }
                if ($taskEntry.Process.ExitCode -ne 0 -or $taskOutput -notmatch $taskMarker -or $taskErrors -match 'SCRIPT ERROR|Parse Error') { throw "Failed: $taskMethod $($taskEntry.Role). See $($taskEntry.Prefix).*log" }
                if ($taskEntry.Role -eq 'client') {
                    if ($taskOutput -notmatch 'accelerated_osr_supported=true' -or $taskOutput -notmatch 'Creating browser in accelerated rendering mode') { throw 'CEF did not confirm accelerated OSR' }
                    if ($Scene -eq 'visual_v1' -and $taskOutput -notmatch 'VISUAL_V1_ENVIRONMENT_OK') { throw 'V1 environment review did not complete' }
                    $taskReport = Get-Content -LiteralPath (Join-Path $taskLogs "$taskCapturePrefix-$taskMethod.json") -Raw | ConvertFrom-Json
                    if ($taskReport.renderer -ne $taskMethod -or $taskReport.driver -ne 'vulkan') { throw 'Native probe used a different renderer/driver' }
                }
                Write-Output "$taskMethod $($taskEntry.Role): PASS"
            }
        } finally {
            foreach ($taskEntry in $taskProcesses) { if (-not $taskEntry.Process.HasExited) { $taskEntry.Process.Kill($true) } }
        }
    }
} finally {
    $env:APPDATA = $taskPreviousAppData
    $env:LOCALAPPDATA = $taskPreviousLocalAppData
}
Write-Output "$taskCapturePrefix synthetic native probe complete. Physical mouse/keyboard, DPI, alt-tab, camera feel and release packaging remain manual gates."
