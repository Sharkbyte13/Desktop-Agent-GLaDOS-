#requires -version 5.1
# Reports the hardware facts that decide which local model to run.
# Reads only. Changes nothing. Writes one text file next to itself.
$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'system-probe.txt'
$lines = New-Object System.Collections.ArrayList
function L { param($t) [void]$lines.Add([string]$t); Write-Host $t }

L ("GLaDOS system probe - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
L ""

L "== GPU =="
$smi = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
if (-not (Test-Path $smi)) { $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source }
if ($smi) {
    $q = & $smi --query-gpu=name,memory.total,memory.used,driver_version --format=csv,noheader 2>&1
    foreach ($r in $q) { L ("  " + $r) }
} else {
    L "  nvidia-smi not found"
}
foreach ($v in (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
    L ("  " + $v.Name + "  driver " + $v.DriverVersion)
}

L ""
L "== CPU / RAM =="
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
L ("  " + $cpu.Name.Trim() + "  cores=" + $cpu.NumberOfCores + " threads=" + $cpu.NumberOfLogicalProcessors)
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
L ("  RAM total " + [math]::Round($os.TotalVisibleMemorySize/1MB,1) + " GB, free " + [math]::Round($os.FreePhysicalMemory/1MB,1) + " GB")
L ("  " + $os.Caption + " build " + $os.BuildNumber)

L ""
L "== Disk (where the models would live) =="
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
    L ("  " + $d.DeviceID + "  free " + [math]::Round($d.FreeSpace/1GB,1) + " GB of " + [math]::Round($d.Size/1GB,1) + " GB")
}

L ""
L "== Already installed? =="
foreach ($n in @('ollama','python','git','winget')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { L ("  " + $n + ": " + $c.Source) } else { L ("  " + $n + ": not on PATH") }
}
$ollamaSvc = Get-Process ollama -ErrorAction SilentlyContinue
L ("  ollama running: " + [bool]$ollamaSvc)

$lines -join "`r`n" | Set-Content -Path $out -Encoding UTF8
Write-Host ""
Write-Host ("  Written to " + $out) -ForegroundColor Green
Start-Sleep -Seconds 8
