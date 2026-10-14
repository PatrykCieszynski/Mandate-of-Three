$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskLogs=Join-Path $taskRoot '.godot/verification'
$taskExe=Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
$taskWriter=$null
$taskPreviousAppData=$env:APPDATA
try {
 $env:APPDATA=Join-Path $taskLogs 'recovery-appdata'
 foreach($taskName in @('market-recovery.db','market-recovery.db-wal','market-recovery.db-shm','market-restored.db','market-restored.db-wal','market-restored.db-shm')) {
  $taskPath=Join-Path $taskLogs $taskName
  if(Test-Path -LiteralPath $taskPath){Remove-Item -LiteralPath $taskPath}
 }
 $taskArgs='--headless --path "'+$taskRoot+'" --mode=world-server res://tests/market_recovery.tscn --recovery-phase=write'
 $taskOut=Join-Path $taskLogs 'market-recovery-writer.out.log'
 $taskWriter=Start-Process $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError (Join-Path $taskLogs 'market-recovery-writer.err.log')
 $taskDeadline=(Get-Date).AddSeconds(30)
 while((Get-Date) -lt $taskDeadline -and -not $taskWriter.HasExited){
  if((Get-Content -LiteralPath $taskOut -Raw -ErrorAction SilentlyContinue) -match 'MARKET_RECOVERY_READY'){break}
  Start-Sleep -Milliseconds 100
 }
 if((Get-Content -LiteralPath $taskOut -Raw) -notmatch 'MARKET_RECOVERY_READY'){throw 'Fixture did not reach committed checkpoint'}
 # Explicit owned disposable process only; never terminate a real server here.
 Stop-Process -Id $taskWriter.Id -Force
 $taskWriter.WaitForExit()
 & python (Join-Path $PSScriptRoot 'market_restore.py')
 if($LASTEXITCODE -ne 0){throw 'WAL restore failed'}
 & $taskExe --headless --path $taskRoot --mode=world-server res://tests/market_recovery.tscn --recovery-phase=read --quit-after 1200 *> (Join-Path $taskLogs 'market-recovery-read.log')
 $taskOutput=Get-Content -LiteralPath (Join-Path $taskLogs 'market-recovery-read.log') -Raw
 if($LASTEXITCODE -ne 0 -or $taskOutput -notmatch 'MARKET_RECOVERY_OK' -or $taskOutput -match 'SCRIPT ERROR|Parse Error'){throw 'Recovery assertions failed'}
 ($taskOutput -split "`r?`n") | Select-String MARKET_DURABILITY_BENCH
 Write-Output 'Marketplace crash/backup/recovery: PASS'
} finally {
 if($taskWriter -and -not $taskWriter.HasExited){Stop-Process -Id $taskWriter.Id -Force}
 $env:APPDATA=$taskPreviousAppData
}
