[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$taskGodot = Join-Path $taskRoot '.godot'
if (-not (Test-Path -LiteralPath $taskGodot)) { return }
if ((Get-Item -LiteralPath $taskGodot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing cleanup through a redirected .godot directory' }
$taskTargets = @('verification','cef-client/project/.godot/verification','cef-spike','check-game-inventory.cjs','check-inventory-click.cjs','check-inventory.cjs','inventory-click-carry.png','inventory-preview-small.png','inventory-preview.png','optional-visual-import.log','optional-visual-test.log')
foreach ($taskRelative in $taskTargets) {
    $taskPath = [IO.Path]::GetFullPath((Join-Path $taskGodot $taskRelative))
    if (-not $taskPath.StartsWith($taskGodot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup target: $taskPath" }
    if (-not (Test-Path -LiteralPath $taskPath)) { continue }
    $taskAncestor = Split-Path -Parent $taskPath
    while ($taskAncestor -ne $taskGodot) {
        if ((Get-Item -LiteralPath $taskAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing redirected cleanup ancestor: $taskAncestor" }
        $taskAncestor = Split-Path -Parent $taskAncestor
    }
    $taskItem = Get-Item -LiteralPath $taskPath -Force
    if ($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing redirected cleanup target: $taskPath" }
    if ($taskRelative -eq 'cef-spike' -and (Test-Path -LiteralPath (Join-Path $taskPath 'reference'))) { throw 'Move the CEF reference checkout before deleting the retired spike cache' }
    # Native PowerShell removes nested links themselves, without invoking another shell.
    if ($PSCmdlet.ShouldProcess($taskPath,'Remove disposable development/test artifacts')) {
        Remove-Item -LiteralPath $taskPath -Recurse -Force
        Write-Output "Removed: $taskRelative"
    }
}
Write-Output 'Preserved: engine binaries, imports/editor cache, references, CEF client/plugin cache and game runtime data.'
