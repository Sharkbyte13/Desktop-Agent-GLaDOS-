#requires -version 5.1
# Removes GLaDOS from startup and shuts down any running instance.
# The folder itself is left alone - delete it yourself if you want her gone.

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

Write-Host ''
Write-Host '  GLaDOS - removal' -ForegroundColor DarkYellow
Write-Host ''

$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'GLaDOS.lnk'

if (Test-Path $lnkPath) {
    Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue
    Write-Host '  [ok] Startup entry removed.' -ForegroundColor Green
} else {
    Write-Host '  [--] No startup entry found.' -ForegroundColor DarkGray
}

$killed = 0
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -like '*glados.ps1*' }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
} catch { }

# The daemons are separate processes and used to survive this, which left a
# microphone open and a model in memory after the program had been removed.
$daemons = 0
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and
                            ($_.CommandLine -like '*listener.py*' -or $_.CommandLine -like '*daemon.py*' -or
                             $_.CommandLine -like '*eye.py*') }
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $daemons++
    }
} catch { }
if ($daemons -gt 0) {
    Write-Host ("  [ok] Stopped " + $daemons + " voice/TTS/eye process(es).") -ForegroundColor Green
}

foreach ($extra in @('GLaDOS-Voice.lnk', 'GLaDOS-TTS.lnk')) {
    $p = Join-Path $startup $extra
    if (Test-Path $p) {
        Remove-Item $p -Force -ErrorAction SilentlyContinue
        Write-Host ('  [ok] Removed ' + $extra + ' from Startup.') -ForegroundColor Green
    }
}

if ($killed -gt 0) {
    Write-Host ("  [ok] Shut down " + $killed + " running instance(s).") -ForegroundColor Green
} else {
    Write-Host '  [--] Nothing was running.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ('  The program folder is still at:') -ForegroundColor DarkYellow
Write-Host ('    ' + $Root) -ForegroundColor DarkGray
Write-Host '  Delete it manually if you want her gone permanently.'
Write-Host ''
Read-Host '  Press Enter to close this window'
