$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'run-npc.ps1') -Scenario upgrade
