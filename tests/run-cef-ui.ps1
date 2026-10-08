param(
    [ValidateSet('Compatibility','Vulkan','Software','Baseline','BaselineVulkan')][string]$Mode = 'Compatibility',
    [switch]$Measure,
    [switch]$Interactive
)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskCache=Join-Path $taskRoot '.godot/cef-spike'
$taskProject=Join-Path $taskCache $(if($Mode -in @('Baseline','BaselineVulkan')){'baseline'}else{'project'})
$taskExe=Join-Path $taskRoot '.godot/Godot_v4.7.2-stable_win64_console.exe'
if(-not(Test-Path (Join-Path $taskProject 'project.godot'))){throw 'Run tools/cef_ui_spike/setup.py first'}
$taskOldAppData=$env:APPDATA
$taskOldLocalAppData=$env:LOCALAPPDATA
$taskKnown=@{}
$taskSamples=@()
$taskCpu=@{}
$taskName=$Mode.ToLower()+$(if($Measure){".measure"}elseif($Interactive){".interactive"}else{""})
try {
    $env:APPDATA=Join-Path $taskRoot '.godot/verification/appdata'
    $env:LOCALAPPDATA=Join-Path $taskRoot '.godot/verification/localappdata'
    $taskImportArgs='--headless --path "'+$taskProject+'" --editor --import --quit'
    $taskImport=Start-Process -FilePath $taskExe -ArgumentList $taskImportArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskCache "$taskName.import.log") -RedirectStandardError (Join-Path $taskCache "$taskName.import.err.log")
    if(-not $taskImport.WaitForExit(30000)){throw 'Spike import timeout'}
    $taskImportErrors=Get-Content (Join-Path $taskCache "$taskName.import.err.log") -Raw
    if($taskImport.ExitCode -ne 0 -or $taskImportErrors -match 'SCRIPT ERROR|Parse Error'){throw 'Spike script import failed'}
    $taskArgs='--path "'+$taskProject+'"'
    if($Mode -in @('Vulkan','BaselineVulkan')){$taskArgs+=' --rendering-method mobile --rendering-driver vulkan'}
    if($Mode -in @('Baseline','BaselineVulkan')){$taskArgs+=' -- --baseline'}
    elseif(-not $Interactive){$taskArgs+=' -- --automated';if($Measure){$taskArgs+=' --measure'}}
    if($Mode -eq 'Software'){$taskArgs+=' --software'}
    $taskOut=Join-Path $taskCache "$taskName.out.log"
    $taskErr=Join-Path $taskCache "$taskName.err.log"
    $taskProcess=Start-Process -FilePath $taskExe -ArgumentList $taskArgs -WorkingDirectory $taskRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    $taskKnown[$taskProcess.Id]=$true
    $taskClock=[Diagnostics.Stopwatch]::StartNew()
    $taskLast=0.0
    while(-not $taskProcess.HasExited){
        if($taskClock.Elapsed.TotalSeconds -gt $(if($Interactive){600}else{100})){throw 'CEF spike timeout'}
        $taskInventory=Get-CimInstance Win32_Process
        do {
            $taskAdded=$false
            foreach($taskInfo in $taskInventory){
                if($taskKnown.ContainsKey([int]$taskInfo.ParentProcessId) -and -not $taskKnown.ContainsKey([int]$taskInfo.ProcessId)){
                    $taskKnown[[int]$taskInfo.ProcessId]=$true
                    $taskAdded=$true
                }
            }
        }while($taskAdded)
        $taskMemory=0L;$taskPrivate=0L;$taskCount=0;$taskDeltaCpu=0.0
        foreach($taskId in @($taskKnown.Keys)){
            $taskChild=Get-Process -Id $taskId -ErrorAction SilentlyContinue
            if($null -eq $taskChild){continue}
            $taskCount++
            $taskMemory+=$taskChild.WorkingSet64
            $taskPrivate+=$taskChild.PrivateMemorySize64
            $taskInfoNow=$taskInventory | Where-Object {[int]$_.ProcessId -eq $taskId} | Select-Object -First 1
            $taskTotal=([double]$taskInfoNow.KernelModeTime+[double]$taskInfoNow.UserModeTime)/10000000.0
            if($taskCpu.ContainsKey($taskId)){$taskDeltaCpu+=[Math]::Max([double]0,[double]($taskTotal-$taskCpu[$taskId]))}
            $taskCpu[$taskId]=$taskTotal
        }
        $taskNow=$taskClock.Elapsed.TotalSeconds
        if($taskNow -ge 10 -and $taskNow -le 18 -and $taskNow -gt $taskLast){
            $taskSamples += [pscustomobject]@{Seconds=[Math]::Round($taskNow,2);PrivateMiB=[Math]::Round($taskPrivate/1MB,1);WorkingSetMiB=[Math]::Round($taskMemory/1MB,1);Processes=$taskCount;CpuOneCorePercent=[Math]::Round(100*$taskDeltaCpu/($taskNow-$taskLast),2)}
        }
        $taskLast=$taskNow
        Start-Sleep -Milliseconds 500
        $taskProcess.Refresh()
    }
    $taskProcess.WaitForExit()
    Start-Sleep -Seconds 2
    $taskAlive=@(Get-CimInstance Win32_Process | Select-Object -ExpandProperty ProcessId)
    $taskAfterTwo=@($taskKnown.Keys | Where-Object {$_ -in $taskAlive})
    $taskRemaining=$taskAfterTwo
    $taskExitWait=[Diagnostics.Stopwatch]::StartNew()
    while($taskRemaining.Count -and $taskExitWait.Elapsed.TotalSeconds -lt 8){
        Start-Sleep -Milliseconds 500
        $taskAlive=@(Get-CimInstance Win32_Process | Select-Object -ExpandProperty ProcessId)
        $taskRemaining=@($taskKnown.Keys | Where-Object {$_ -in $taskAlive})
    }
    $taskText=Get-Content -LiteralPath $taskOut -Raw
    $taskPass=$taskText -match $(if($Mode -in @('Baseline','BaselineVulkan')){'CEF_BASELINE_DONE'}else{'CEF_AUTOMATED_RESULT:.*"ok":true'})
    $taskSummary=[pscustomobject]@{Mode=$Mode;ExitCode=$taskProcess.ExitCode;Pass=$taskPass;SurvivorsAfterTwoSeconds=$taskAfterTwo;OrphanPids=$taskRemaining;Samples=$taskSamples}
    $taskSummary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $taskCache "$taskName.metrics.json")
    $taskSummary | Select-Object Mode,ExitCode,Pass,@{Name='Orphans';Expression={$_.OrphanPids.Count}} | Format-Table
    if($taskSamples.Count){$taskSamples | Measure-Object -Property PrivateMiB,WorkingSetMiB,CpuOneCorePercent,Processes -Average | Select-Object Property,Average | Format-Table}
    if(-not $Interactive -and (-not $taskPass -or $taskProcess.ExitCode -ne 0 -or $taskRemaining.Count)){throw "CEF $Mode failed; inspect $taskCache"}
} finally {
    # Cleanup is restricted to descendants observed from this exact owned launch.
    foreach($taskId in @($taskKnown.Keys)){
        $taskChild=Get-Process -Id $taskId -ErrorAction SilentlyContinue
        if($null -ne $taskChild -and ($taskChild.ProcessName -like 'Godot*' -or $taskChild.ProcessName -eq 'gdcef_helper')){Stop-Process -Id $taskId -ErrorAction SilentlyContinue}
    }
    $env:APPDATA=$taskOldAppData
    $env:LOCALAPPDATA=$taskOldLocalAppData
}
