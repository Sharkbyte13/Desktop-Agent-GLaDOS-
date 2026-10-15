#requires -version 5.1
# ===========================================================================
#  GLaDOS local TTS - setup
#
#  Builds a private Python environment next to this script, fetches the
#  glados-tts model, and proves the whole chain by synthesizing one line.
#
#  Nothing here is installed system-wide except Python itself, and only if
#  you do not already have it. Everything else lives in .venv and models/
#  inside this folder. Delete the folder to remove it all.
# ===========================================================================

# Deliberately NOT 'Stop'. Native tools (pip, gdown, winget) write progress and
# warnings to stderr, and with 'Stop' PowerShell promotes any stderr write from
# a native command into a terminating error - which killed the model download
# the moment gdown printed "Downloading...". Every step below validates its own
# outcome explicitly instead: a file exists, an import succeeds, an exit code is
# zero. That is a better test than "the tool stayed quiet".
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

$script:LogPath = Join-Path $Root 'install-tts.log'
try { Set-Content -Path $script:LogPath -Encoding UTF8 `
        -Value ("GLaDOS TTS setup - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) } catch { }

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
    Start-Sleep -Seconds 30
    exit 1
}

Write-Host ''
Write-Host '  APERTURE SCIENCE - VOCAL SUBSYSTEM INSTALLATION' -ForegroundColor DarkYellow
Write-Host ''
Say ("Root: " + $Root)

$MODEL_ID  = '1TRJtctjETgVVD5p7frSVPmgw8z8FFtjD'
$MODEL_URL = "https://drive.google.com/uc?id=$MODEL_ID"
$NEEDED = @(
    'models\glados-new.pt',
    'models\vocoder-gpu.pt',
    'models\emb\glados_p2.pt',
    'models\en_us_cmudict_ipa_forward.pt'
)

# ---------------------------------------------------------------------------
Step 'Step 1 of 6: locating Python'
# ---------------------------------------------------------------------------

function Find-Python {
    # The py launcher is the most reliable when it exists.
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
                # The Microsoft Store stub is a zero-byte redirector, not Python.
                if ($exe -and (Test-Path $exe) -and ((Get-Item $exe).Length -gt 0)) {
                    $v = & $exe -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
                    if ($v) {
                        $parts = $v.Trim().Split('.')
                        $maj = [int]$parts[0]; $min = [int]$parts[1]
                        if ($maj -eq 3 -and $min -ge 9 -and $min -le 13) {
                            return @{ exe = $exe; version = $v.Trim() }
                        }
                        Say ("  found Python " + $v.Trim() + " at " + $exe + " (need 3.9-3.13)")
                    }
                }
            }
        } catch { }
    }
    return $null
}

$py = Find-Python

if (-not $py) {
    Say '  No suitable Python found. Trying winget...' 'DarkGray'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail ("Python 3.9-3.13 is not installed and winget is unavailable." + [Environment]::NewLine +
              "      Install Python from https://www.python.org/downloads/ " +
              "(tick 'Add python.exe to PATH'), then run this again.")
    }
    & winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements --silent 2>&1 |
        ForEach-Object { Say ("  winget: " + $_) 'DarkGray' }
    # winget does not refresh this process's PATH.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    $py = Find-Python
    if (-not $py) {
        Fail ("Python still not found after the winget install." + [Environment]::NewLine +
              "      Close this window, open a new one, and run Setup-TTS.cmd again - " +
              "a fresh window will pick up the new PATH.")
    }
}
Say ("  [ok] Python " + $py.version + " at " + $py.exe) 'Green'

# ---------------------------------------------------------------------------
Step 'Step 2 of 6: creating the private environment'
# ---------------------------------------------------------------------------

$venv    = Join-Path $Root '.venv'
$venvPy  = Join-Path $venv 'Scripts\python.exe'

if (Test-Path $venvPy) {
    Say '  [ok] .venv already exists, reusing it.' 'Green'
} else {
    & $py.exe -m venv $venv 2>&1 | ForEach-Object { Say ("  " + $_) 'DarkGray' }
    if (-not (Test-Path $venvPy)) { Fail "venv creation failed - no python.exe under .venv\Scripts" }
    Say ('  [ok] created ' + $venv) 'Green'
}

& $venvPy -m pip install --upgrade pip --quiet 2>&1 | ForEach-Object { Say ("  " + $_) 'DarkGray' }

# ---------------------------------------------------------------------------
Step 'Step 3 of 6: installing PyTorch and friends (this is the slow one)'
# ---------------------------------------------------------------------------

Say '  Downloading roughly 250 MB. Several minutes is normal.' 'DarkGray'

& $venvPy -m pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu 2>&1 |
    ForEach-Object { Say ("  " + $_) 'DarkGray' }
$torchOk = ($LASTEXITCODE -eq 0)

if (-not $torchOk) {
    Say '  Falling back to the default PyPI wheel (larger).' 'DarkGray'
    & $venvPy -m pip install --quiet torch 2>&1 | ForEach-Object { Say ("  " + $_) 'DarkGray' }
}

& $venvPy -m pip install --quiet numpy scipy inflect Unidecode deep_phonemizer gdown 2>&1 |
    ForEach-Object { Say ("  " + $_) 'DarkGray' }

$check = & $venvPy -c "import torch,scipy,numpy,inflect,unidecode,dp;print('OK',torch.__version__)" 2>&1
if ($check -notmatch '^OK') { Fail ("dependency check failed: " + ($check -join ' ')) }
Say ("  [ok] " + ($check -join ' ')) 'Green'

# ---------------------------------------------------------------------------
Step 'Step 4 of 6: fetching the voice model'
# ---------------------------------------------------------------------------

$zip = Join-Path $Root 'models.zip'
$haveAll = $true
foreach ($n in $NEEDED) { if (-not (Test-Path (Join-Path $Root $n))) { $haveAll = $false } }

if ($haveAll) {
    Say '  [ok] Model files already present, skipping download.' 'Green'
} else {
    if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) {
        Say ('  [ok] Found an existing models.zip (' +
             [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB), using it.') 'Green'
    } else {
        if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        Say '  Downloading from Google Drive. Drive is awkward about large files,' 'DarkGray'
        Say '  so there are three attempts with different strategies.' 'DarkGray'

        $attempts = @(
            @{ label = 'by file id';        args = @('-m', 'gdown', $MODEL_ID, '-O', $zip) },
            @{ label = 'by url, fuzzy';     args = @('-m', 'gdown', $MODEL_URL, '-O', $zip, '--fuzzy') },
            @{ label = 'by id, no cookies'; args = @('-m', 'gdown', $MODEL_ID, '-O', $zip, '--no-cookies') }
        )

        foreach ($a in $attempts) {
            # Clear any partial file gdown left behind, or it resumes garbage.
            Get-ChildItem -Path $Root -Filter 'models.zip*.part' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue

            Say ('  attempt: ' + $a.label + ' ...')
            & $venvPy $a.args 2>&1 | ForEach-Object { Say ("    " + $_) 'DarkGray' }

            if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) {
                Say ('  [ok] downloaded ' +
                     [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB') 'Green'
                break
            }
            Say ('    that attempt produced nothing usable.') 'DarkGray'
        }

        Get-ChildItem -Path $Root -Filter 'models.zip*.part' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 1MB) {
        if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        Fail ("All three download attempts failed." + [Environment]::NewLine +
              [Environment]::NewLine +
              "      Do it by hand instead, it takes one minute:" + [Environment]::NewLine +
              "        1. Open this in your browser:" + [Environment]::NewLine +
              "           $MODEL_URL" + [Environment]::NewLine +
              "        2. Download the file (click through the virus-scan warning)." + [Environment]::NewLine +
              "        3. Save it as models.zip in:" + [Environment]::NewLine +
              "           $Root" + [Environment]::NewLine +
              "        4. Run Setup-TTS.cmd again - it will find the zip and skip the download.")
    }

    Say ('  Extracting ' + [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB...')
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmp = Join-Path $Root '_unzip'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    } catch {
        Fail ("Extraction failed: " + $_.Exception.Message + [Environment]::NewLine +
              "      The zip is probably truncated. Delete models.zip and try again.")
    }

    # The archive's internal layout is not guaranteed, so find each file by
    # name and put it where the daemon expects it.
    $modelsDir = Join-Path $Root 'models'
    New-Item -ItemType Directory -Force -Path (Join-Path $modelsDir 'emb') | Out-Null
    $map = @{
        'glados-new.pt'                = Join-Path $modelsDir 'glados-new.pt'
        'vocoder-gpu.pt'               = Join-Path $modelsDir 'vocoder-gpu.pt'
        'glados_p2.pt'                 = Join-Path $modelsDir 'emb\glados_p2.pt'
        'en_us_cmudict_ipa_forward.pt' = Join-Path $modelsDir 'en_us_cmudict_ipa_forward.pt'
    }
    foreach ($name in $map.Keys) {
        $found = Get-ChildItem -Path $tmp -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName $map[$name] -Force
            Say ('    placed ' + $name + '  (' + [math]::Round($found.Length / 1MB, 1) + ' MB)') 'DarkGray'
        } else {
            Say ('    MISSING from archive: ' + $name) 'Red'
        }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$missing = @()
foreach ($n in $NEEDED) { if (-not (Test-Path (Join-Path $Root $n))) { $missing += $n } }
if ($missing.Count) { Fail ("Model files still missing: " + ($missing -join ', ')) }
Say '  [ok] All four model files present.' 'Green'

# ---------------------------------------------------------------------------
Step 'Step 5 of 6: synthesizing a test line'
# ---------------------------------------------------------------------------

Say '  First run loads the model and warms up. Give it a minute.' 'DarkGray'
$sayWav = Join-Path $Root 'say.wav'
if (Test-Path $sayWav) { Remove-Item $sayWav -Force -ErrorAction SilentlyContinue }

$testLine = 'Vocal subsystem online. Try to contain your enthusiasm.'
& $venvPy (Join-Path $Root 'daemon.py') --root $Root --say $testLine 2>&1 |
    ForEach-Object { Say ("  " + $_) 'DarkGray' }

if (-not (Test-Path $sayWav)) { Fail "The test synthesis produced no audio. See tts.log in this folder." }
$wavLen = (Get-Item $sayWav).Length
if ($wavLen -lt 2000) { Fail ("The test audio is only $wavLen bytes - synthesis is not working properly.") }
Say ("  [ok] say.wav written, " + [math]::Round($wavLen / 1KB, 1) + " KB") 'Green'

try {
    Say '  Playing it back...' 'DarkGray'
    (New-Object System.Media.SoundPlayer $sayWav).PlaySync()
} catch { Say ('  (playback failed: ' + $_.Exception.Message + ')') 'DarkGray' }

# ---------------------------------------------------------------------------
Step 'Step 6 of 6: wiring it up'
# ---------------------------------------------------------------------------

# Point the overlay at the daemon.
$overlayCfg = Join-Path (Split-Path -Parent $Root) 'config.json'
if (Test-Path $overlayCfg) {
    try {
        $cfg = Get-Content $overlayCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg.ttsEngine = 'http'
        ($cfg | ConvertTo-Json -Depth 4) | Set-Content $overlayCfg -Encoding UTF8
        Say '  [ok] Overlay switched to the http engine.' 'Green'
        Say '       Restart her (tray icon -> Shut down, then Install.cmd) to pick it up.' 'DarkGray'
    } catch {
        Say ('  [--] Could not edit the overlay config: ' + $_.Exception.Message) 'DarkGray'
        Say '       Set "ttsEngine": "http" in config.json by hand.' 'DarkGray'
    }
} else {
    Say ('  [--] No overlay config at ' + $overlayCfg) 'DarkGray'
}

# No Startup shortcut of its own: the overlay starts the daemon when it starts
# and stops it when it shuts down, the same bargain the listener has. An old
# shortcut from a previous install is removed, or it would start a second
# daemon at every login - and the second one cannot bind the port.
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'GLaDOS-TTS.lnk'
if (Test-Path $lnkPath) {
    try {
        Remove-Item $lnkPath -Force -ErrorAction Stop
        Say '  [ok] Removed the old TTS Startup entry (the overlay owns it now).' 'Green'
    } catch {
        Say ('  [!!] Could not remove ' + $lnkPath + ': ' + $_.Exception.Message) 'Red'
    }
}
Say '  [ok] The daemon starts and stops with GLaDOS.' 'Green'

# Start it now.
try {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                  -ArgumentList ('"' + (Join-Path $Root 'start-tts.vbs') + '"') -WorkingDirectory $Root
    Start-Sleep -Seconds 4
    $ok = $false
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8124/health' -TimeoutSec 3
            if ($r.ok) { $ok = $true; break }
        } catch { Start-Sleep -Seconds 2 }
    }
    if ($ok) { Say '  [ok] Daemon answering on http://127.0.0.1:8124' 'Green' }
    else     { Say '  [!!] Daemon did not answer /health. See tts.log.' 'Red' }
} catch {
    Say ('  [!!] Could not start the daemon: ' + $_.Exception.Message) 'Red'
}

Write-Host ''
Say '  Done.' 'DarkYellow'
Say ''
Say '  In her chat window:  /voice http    then   /voice test'
Say '  Daemon controls:     Start-TTS.cmd / Stop-TTS.cmd'
Say ('  Logs:                ' + $script:LogPath + '  and  tts.log')
Write-Host ''
for ($i = 30; $i -gt 0; $i--) {
    Write-Host ("`r  Closing in " + $i + " seconds...   ") -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
