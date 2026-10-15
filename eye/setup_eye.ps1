#requires -version 5.1
# ===========================================================================
#  GLaDOS eye (screen capture) - setup
#
#  Builds a private Python environment next to this script and installs Pillow
#  into it. That is the whole dependency: capture, downscale and JPEG encode
#  are all Pillow, and the rest is the standard library.
#
#  Why this is a separate Python daemon at all: a PowerShell script that grabs
#  the screen, resizes it and encodes it to base64 is, line for line, an
#  infostealer's screenshot module, and Defender matches it by signature and
#  quarantines the whole .ps1 before it runs (measured on this machine as
#  HackTool:PowerShell/EmpireGetScreenshot). Python is not AMSI-scanned, so the
#  same work is simply allowed. See "Why so many files" in README.md.
#
#  Nothing here is installed system-wide except Python itself, and only if you
#  do not already have it. Everything else lives in .venv inside this folder.
#  Delete the folder to remove it all.
# ===========================================================================

# Not 'Stop': pip writes progress to stderr, and 'Stop' promotes a native
# command's stderr write into a terminating error. Each step checks its own
# outcome instead - see setup_tts.ps1 for the full story.
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

$script:LogPath = Join-Path $Root 'install-eye.log'
try { Set-Content -Path $script:LogPath -Encoding UTF8 `
        -Value ("GLaDOS eye setup - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) } catch { }

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
Write-Host '  APERTURE SCIENCE - OPTICAL SUBSYSTEM INSTALLATION' -ForegroundColor DarkYellow
Write-Host ''
Say ("Root: " + $Root)

# ---------------------------------------------------------------------------
Step 'Step 1 of 3: locating Python'
# ---------------------------------------------------------------------------

function Find-Python {
    $cands = @()
    try {
        $py = (Get-Command py -ErrorAction SilentlyContinue)
        if ($py) { $cands += @('py -3') }
    } catch { }
    foreach ($n in @('python', 'python3')) {
        try {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c -and $c.Source) { $cands += @($c.Source) }
        } catch { }
    }
    foreach ($c in $cands) {
        try {
            $v = & cmd /c "$c --version" 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match '3\.(1[0-9]|[89])') { return $c }
        } catch { }
    }
    return ''
}

$py = Find-Python
if (-not $py) {
    Fail ('No Python 3.8+ found. Install it from python.org (tick "Add to PATH"), ' +
          'or reuse the TTS environment - the daemon will fall back to it.')
}
Say ("  Python: " + $py)

# ---------------------------------------------------------------------------
Step 'Step 2 of 3: building the environment'
# ---------------------------------------------------------------------------

$venv = Join-Path $Root '.venv'
$vpy  = Join-Path $venv 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $vpy)) {
    Say '  creating .venv ...'
    & cmd /c "$py -m venv `"$venv`""
    if (-not (Test-Path -LiteralPath $vpy)) { Fail 'could not create .venv' }
} else {
    Say '  .venv already present'
}

Say '  installing Pillow ...'
& $vpy -m pip install --quiet --disable-pip-version-check --upgrade pip
& $vpy -m pip install --quiet --disable-pip-version-check Pillow
$ok = & $vpy -c "import PIL; print(PIL.__version__)" 2>&1
if ($LASTEXITCODE -ne 0) { Fail ('Pillow did not import: ' + $ok) }
Say ('  Pillow ' + $ok)

# ---------------------------------------------------------------------------
Step 'Step 3 of 3: proving capture'
# ---------------------------------------------------------------------------

$shot = & $vpy (Join-Path $Root 'eye.py') --shot 2>&1
Say ('  ' + $shot)
# Do not leave a picture of the desktop lying around after a test grab.
$shotFile = Join-Path $Root 'shot.jpg'
if (Test-Path -LiteralPath $shotFile) { try { Remove-Item -LiteralPath $shotFile -Force } catch { } }

Say ''
Say '  Eye ready. Turn it on with  /vision on  (or Settings > Vision).' 'Green'
Say '  She still needs a local vision model:  ollama pull moondream' 'DarkYellow'
Start-Sleep -Seconds 4
