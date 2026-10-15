#requires -version 5.1
# ===========================================================================
#  GLaDOS voice input - setup
#
#  Builds a private Python environment next to this script, fetches the wake
#  word and speech recognition models, then proves the microphone works by
#  recording you and reading back what it heard.
#
#  Everything lives in .venv and models/ inside this folder. Delete the folder
#  to remove it all. Nothing is installed system-wide except Python, and only
#  if you do not already have it.
# ===========================================================================

# Not 'Stop'. Native tools write progress to stderr and PowerShell 5.1 turns
# that into a terminating error, which is how the model download died the
# first time. Each step validates its own outcome instead.
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

$script:LogPath = Join-Path $Root 'install-voice.log'
try { Set-Content -Path $script:LogPath -Encoding UTF8 `
        -Value ("GLaDOS voice setup - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) } catch { }

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    try { Add-Content -Path $script:LogPath -Encoding UTF8 -Value $Text } catch { }
}
function Step { param([string]$T) Say '' ; Say ("== " + $T) 'DarkYellow' }
function Fail {
    param([string]$T)
    Say ("  [!!] " + $T) 'Red'
    Say ''
    Say ("  Log: " + $script:LogPath) 'DarkGray'
    Start-Sleep -Seconds 40
    exit 1
}

Write-Host ''
Write-Host '  APERTURE SCIENCE - AUDITORY SUBSYSTEM INSTALLATION' -ForegroundColor DarkYellow
Write-Host ''
Say ("Root: " + $Root)

# Chosen from the system probe: i9-10850K, 20 threads. base.en on CPU
# transcribes several times faster than real time and never touches the
# 2080 Ti, which has better things to do.
$WHISPER_MODEL   = 'base.en'
$WHISPER_DEVICE  = 'cpu'
$WHISPER_COMPUTE = 'int8'

# ---------------------------------------------------------------------------
Step 'Step 1 of 6: locating Python'
# ---------------------------------------------------------------------------

function Find-Python {
    foreach ($probe in @(
        @{ exe = 'py';     args = @('-3.12', '-c', 'import sys;print(sys.executable)') },
        @{ exe = 'py';     args = @('-3.11', '-c', 'import sys;print(sys.executable)') },
        @{ exe = 'py';     args = @('-3',    '-c', 'import sys;print(sys.executable)') },
        @{ exe = 'python'; args = @('-c', 'import sys;print(sys.executable)') }
    )) {
        try {
            $out = & $probe.exe $probe.args 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $exe = ($out | Select-Object -First 1).Trim()
                # WindowsApps\python.exe is a zero-byte Store redirector, not
                # Python. It is first on PATH on this machine.
                if ($exe -and (Test-Path $exe) -and ((Get-Item $exe).Length -gt 0)) {
                    $v = & $exe -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
                    if ($v) {
                        $parts = $v.Trim().Split('.')
                        if ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 9 -and [int]$parts[1] -le 13) {
                            return @{ exe = $exe; version = $v.Trim() }
                        }
                    }
                }
            }
        } catch { }
    }
    return $null
}

$py = Find-Python
if (-not $py) {
    Fail ("No usable Python 3.9-3.13 found." + [Environment]::NewLine +
          "      The TTS installer found one at %LOCALAPPDATA%\Programs\Python\Python312 - " +
          "if that is gone, reinstall from python.org with 'Add to PATH' ticked.")
}
Say ("  [ok] Python " + $py.version + " at " + $py.exe) 'Green'

# ---------------------------------------------------------------------------
Step 'Step 2 of 6: creating the private environment'
# ---------------------------------------------------------------------------

$venv   = Join-Path $Root '.venv'
$venvPy = Join-Path $venv 'Scripts\python.exe'

if (Test-Path $venvPy) {
    Say '  [ok] .venv already exists, reusing it.' 'Green'
} else {
    & $py.exe -m venv $venv 2>&1 | ForEach-Object { Say ("  " + $_) 'DarkGray' }
    if (-not (Test-Path $venvPy)) { Fail "venv creation failed - no python.exe under .venv\Scripts" }
    Say ('  [ok] created ' + $venv) 'Green'
}
& $venvPy -m pip install --upgrade pip --quiet 2>&1 | ForEach-Object { Say ("  " + $_) 'DarkGray' }

# ---------------------------------------------------------------------------
Step 'Step 3 of 6: installing audio and recognition libraries'
# ---------------------------------------------------------------------------

Say '  Roughly 300 MB. A few minutes.' 'DarkGray'
& $venvPy -m pip install --quiet numpy sounddevice openwakeword faster-whisper 2>&1 |
    ForEach-Object { Say ("  " + $_) 'DarkGray' }

$check = & $venvPy -c "import numpy,sounddevice,openwakeword,faster_whisper,onnxruntime;print('OK',onnxruntime.__version__)" 2>&1
if ($check -notmatch '^OK') { Fail ("dependency check failed: " + ($check -join ' ')) }
Say ("  [ok] onnxruntime " + (($check -join ' ').Split(' ')[1])) 'Green'

# ---------------------------------------------------------------------------
Step 'Step 4 of 6: fetching the wake word models'
# ---------------------------------------------------------------------------

Say '  Pretrained models (hey jarvis, alexa, ...) plus the shared feature extractor.' 'DarkGray'
& $venvPy -c "import openwakeword.utils as u; u.download_models(); print('MODELS_OK')" 2>&1 |
    ForEach-Object { Say ("  " + $_) 'DarkGray' }

$mv = & $venvPy -c "import openwakeword,os;p=os.path.join(os.path.dirname(openwakeword.__file__),'resources','models');print(len([f for f in os.listdir(p) if f.endswith('.onnx')]) if os.path.isdir(p) else 0)" 2>&1
if (($mv -join '') -match '^\d+$' -and [int]($mv -join '') -gt 0) {
    Say ("  [ok] " + ($mv -join '') + " wake models available") 'Green'
} else {
    Fail "openWakeWord model download produced nothing. Check your connection and retry."
}

$custom = Join-Path $Root 'models\hey_glados.onnx'
if (Test-Path $custom) {
    Say '  [ok] Custom hey_glados.onnx found - that will be used.' 'Green'
} else {
    Say '  [--] No custom hey_glados.onnx yet, so "hey jarvis" is the wake word' 'DarkYellow'
    Say '       for now. See WAKE-WORD-TRAINING.md to train the real one.' 'DarkYellow'
}

# ---------------------------------------------------------------------------
Step 'Step 5 of 6: microphone and recognition test'
# ---------------------------------------------------------------------------

Say '  Input devices this machine offers:' 'DarkGray'
& $venvPy (Join-Path $Root 'listener.py') --list-devices 2>&1 |
    ForEach-Object { Say ("    " + $_) 'DarkGray' }

Write-Host ''
Say '  About to record you for 5 seconds and read back what it heard.' 'DarkYellow'
Say '  Say anything - a whole sentence works better than one word.' 'DarkYellow'
Write-Host ''
for ($i = 3; $i -gt 0; $i--) {
    Write-Host ("`r  Starting in " + $i + "...   ") -NoNewline -ForegroundColor DarkYellow
    Start-Sleep -Seconds 1
}
Write-Host ''

$heard = & $venvPy (Join-Path $Root 'listener.py') --selftest 5 `
            --whisper-model $WHISPER_MODEL --whisper-device $WHISPER_DEVICE `
            --whisper-compute $WHISPER_COMPUTE 2>&1
$exit = $LASTEXITCODE
foreach ($l in $heard) { Say ("  " + $l) }

if ($exit -eq 2) {
    Fail ("The microphone captured almost nothing." + [Environment]::NewLine +
          "      Windows Settings -> System -> Sound -> Input: pick the right device" + [Environment]::NewLine +
          "      and check its level, then run Setup-Voice.cmd again." + [Environment]::NewLine +
          "      Also check Privacy -> Microphone -> let desktop apps access it.")
}
if ($exit -ne 0) {
    Say '  [!!] The mic works but nothing was recognised. Continuing anyway -' 'Red'
    Say '       you can retest later with a longer sentence.' 'Red'
} else {
    Say '  [ok] Microphone and speech recognition both working.' 'Green'
}

# ---------------------------------------------------------------------------
Step 'Step 6 of 6: wiring it up'
# ---------------------------------------------------------------------------

# Record the chosen recognizer settings for the launcher to read.
$cfg = @{
    whisperModel   = $WHISPER_MODEL
    whisperDevice  = $WHISPER_DEVICE
    whisperCompute = $WHISPER_COMPUTE
    threshold      = 0.5
}
try {
    ($cfg | ConvertTo-Json) | Set-Content -Path (Join-Path $Root 'voice-config.json') -Encoding UTF8
    Say '  [ok] voice-config.json written.' 'Green'
} catch {
    Say ('  [--] Could not write voice-config.json: ' + $_.Exception.Message) 'DarkGray'
}

# No Startup shortcut of its own. The overlay starts the listener when it
# starts and stops it when it shuts down, because a microphone that outlives
# the window listening to it is a microphone nobody knows is on. An old
# shortcut from a previous install is removed here, or it would go on starting
# a second listener at every login.
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'GLaDOS-Voice.lnk'
if (Test-Path $lnkPath) {
    try {
        Remove-Item $lnkPath -Force -ErrorAction Stop
        Say '  [ok] Removed the old listener Startup entry (the overlay owns it now).' 'Green'
    } catch {
        Say ('  [!!] Could not remove ' + $lnkPath + ': ' + $_.Exception.Message) 'Red'
    }
}
Say '  [ok] The listener starts and stops with GLaDOS.' 'Green'

try {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                  -ArgumentList ('"' + (Join-Path $Root 'start-voice.vbs') + '"') -WorkingDirectory $Root
    Start-Sleep -Seconds 6
    $running = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -and $_.CommandLine -like '*listener.py*' })
    if ($running.Count -gt 0) { Say ('  [ok] Listener running (pid ' + $running[0].ProcessId + ').') 'Green' }
    else { Say '  [!!] Listener is not running. See voice.log.' 'Red' }
} catch {
    Say ('  [!!] Could not start the listener: ' + $_.Exception.Message) 'Red'
}

Write-Host ''
Say '  Done.' 'DarkYellow'
Say ''
if (Test-Path $custom) {
    Say '  Say "Hey GLaDOS", wait for her to answer, then talk.'
} else {
    Say '  Say "Hey Jarvis", wait, then talk. Yes, the wrong name - train the'
    Say '  real one with WAKE-WORD-TRAINING.md and it swaps straight in.'
}
Say ''
Say '  Controls:   Start-Voice.cmd / Stop-Voice.cmd, or Mute microphone in her tray menu'
Say ('  Logs:       ' + $script:LogPath + '  and  voice.log')
Write-Host ''
for ($i = 30; $i -gt 0; $i--) {
    Write-Host ("`r  Closing in " + $i + " seconds...   ") -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
