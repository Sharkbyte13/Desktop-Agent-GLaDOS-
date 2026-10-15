#requires -version 5.1
# ===========================================================================
#  GLaDOS local brain - setup
#
#  Installs Ollama, configures it not to squat on your VRAM, pulls a
#  tool-capable model, and proves BOTH that it talks and that it can call
#  tools - because the assistant is built on tool calling, and a model that
#  chats but cannot call a function is useless here.
# ===========================================================================

# Not 'Stop'. winget and ollama both report progress on stderr, and PowerShell
# 5.1 promotes that to a terminating error. Every step validates its outcome.
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot

$script:LogPath = Join-Path $Root 'install-brain.log'
try { Set-Content -Path $script:LogPath -Encoding UTF8 `
        -Value ("GLaDOS brain setup - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) } catch { }

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
Write-Host '  APERTURE SCIENCE - COGNITIVE SUBSYSTEM INSTALLATION' -ForegroundColor DarkYellow
Write-Host ''
Say ("Root: " + $Root)

$API = 'http://127.0.0.1:11434'

# Ranked. The first one that actually pulls wins. A list rather than a single
# name because model tags come and go, and a stale tag should degrade to the
# next choice instead of failing the whole install.
$CANDIDATES = @(
    @{ tag = 'qwen3:8b';     note = 'strong tool calling, 40K context, ~5.2GB' },
    @{ tag = 'llama3.1:8b';  note = 'proven tool calling, ~4.7GB' },
    @{ tag = 'qwen2.5:7b';   note = 'smaller fallback, ~4.7GB' },
    @{ tag = 'qwen3:4b';     note = 'last resort, fits tight VRAM, ~2.6GB' }
)

# ---------------------------------------------------------------------------
Step 'Step 1 of 6: installing Ollama'
# ---------------------------------------------------------------------------

$ollama = (Get-Command ollama -ErrorAction SilentlyContinue)
if (-not $ollama) {
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $guess) { $ollama = @{ Source = $guess } }
}

if ($ollama) {
    Say ('  [ok] Already installed: ' + $ollama.Source) 'Green'
} else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail ("Ollama is not installed and winget is unavailable." + [Environment]::NewLine +
              "      Install it from https://ollama.com/download then run this again.")
    }
    Say '  Installing via winget. A few minutes.' 'DarkGray'
    & winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements --silent 2>&1 |
        ForEach-Object { Say ("  winget: " + $_) 'DarkGray' }

    # winget does not refresh this process's PATH.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue)
    if (-not $ollama) {
        $guess = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (Test-Path $guess) { $ollama = @{ Source = $guess } }
    }
    if (-not $ollama) {
        Fail ("Ollama still not found after install." + [Environment]::NewLine +
              "      Close this window, open a new one and run Setup-Brain.cmd again - " +
              "a fresh window picks up the new PATH.")
    }
    Say ('  [ok] Installed: ' + $ollama.Source) 'Green'
}
$OLLAMA = $ollama.Source

# ---------------------------------------------------------------------------
Step 'Step 2 of 6: teaching it to let go of your VRAM'
# ---------------------------------------------------------------------------

# Your 2080 Ti has 11GB and you had 8.8GB of it in use at idle. These two
# settings are the difference between a model that shares the card and one
# that squats on it.
$envVars = @{
    'OLLAMA_KEEP_ALIVE'        = '5m'   # unload 5 min after the last message
    'OLLAMA_MAX_LOADED_MODELS' = '1'    # never hold two models at once
}
foreach ($k in $envVars.Keys) {
    try {
        [Environment]::SetEnvironmentVariable($k, $envVars[$k], 'User')
        Set-Item -Path ("env:" + $k) -Value $envVars[$k] -ErrorAction SilentlyContinue
        Say ("  [ok] " + $k + " = " + $envVars[$k]) 'Green'
    } catch {
        Say ("  [!!] could not set " + $k + ": " + $_.Exception.Message) 'Red'
    }
}
Say '       keep_alive 5m: the model leaves VRAM five minutes after you stop' 'DarkGray'
Say '       talking, and reloads in a second or two when you start again.' 'DarkGray'

# Ollama reads these at startup, so it has to be restarted to see them.
Say '  Restarting Ollama so it picks the settings up...' 'DarkGray'
Get-Process ollama, 'ollama app' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
}
Start-Sleep -Seconds 2
$appExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
if (Test-Path $appExe) { Start-Process $appExe } else { Start-Process $OLLAMA -ArgumentList 'serve' -WindowStyle Hidden }

# ---------------------------------------------------------------------------
Step 'Step 3 of 6: waiting for the server'
# ---------------------------------------------------------------------------

$up = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $v = Invoke-RestMethod -Uri ($API + '/api/version') -TimeoutSec 3
        Say ('  [ok] Ollama ' + $v.version + ' answering on ' + $API) 'Green'
        $up = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $up) { Fail "Ollama never answered on $API. Check that the Ollama tray app is running." }

# ---------------------------------------------------------------------------
Step 'Step 4 of 6: pulling a tool-capable model'
# ---------------------------------------------------------------------------

$have = @()
try { $have = @((Invoke-RestMethod -Uri ($API + '/api/tags') -TimeoutSec 10).models | ForEach-Object { $_.name }) } catch { }
if ($have.Count) { Say ('  Already present: ' + ($have -join ', ')) 'DarkGray' }

$MODEL = $null
foreach ($c in $CANDIDATES) {
    if ($have -contains $c.tag) { $MODEL = $c.tag; Say ('  [ok] ' + $c.tag + ' already downloaded.') 'Green'; break }
}

if (-not $MODEL) {
    foreach ($c in $CANDIDATES) {
        Say ('  Trying ' + $c.tag + '  (' + $c.note + ')')
        Say '  This is several GB. Progress is shown below.' 'DarkGray'
        & $OLLAMA pull $c.tag 2>&1 | ForEach-Object { Say ("    " + $_) 'DarkGray' }

        $ok = $false
        try {
            $tags = @((Invoke-RestMethod -Uri ($API + '/api/tags') -TimeoutSec 10).models | ForEach-Object { $_.name })
            $ok = ($tags | Where-Object { $_ -eq $c.tag -or $_ -like ($c.tag + '*') }).Count -gt 0
        } catch { }

        if ($ok) { $MODEL = $c.tag; Say ('  [ok] ' + $c.tag + ' downloaded.') 'Green'; break }
        Say ('  ' + $c.tag + ' did not pull. Trying the next candidate.') 'DarkGray'
    }
}
if (-not $MODEL) { Fail "None of the candidate models could be downloaded. Check your connection." }

# ---------------------------------------------------------------------------
Step 'Step 5 of 6: proving it works'
# ---------------------------------------------------------------------------

Say '  (a) plain reply...' 'DarkGray'
$bodyA = '{"model":' + ($MODEL | ConvertTo-Json) +
         ',"stream":false,"messages":[{"role":"user","content":"Reply with exactly: SYSTEMS NOMINAL"}]}'
$replyA = $null
try {
    $r = Invoke-RestMethod -Uri ($API + '/api/chat') -Method Post -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyA)) -TimeoutSec 180
    $replyA = [string]$r.message.content
} catch {
    Fail ("The model did not reply: " + $_.Exception.Message)
}
Say ('      said: ' + ($replyA -replace '\s+', ' ')) 'DarkGray'
if ($replyA) { Say '  [ok] It talks.' 'Green' } else { Fail "Empty reply from the model." }

Say '  (b) tool calling - the part everything else depends on...' 'DarkGray'
# Hand-built JSON: PowerShell 5.1 collapses single-element arrays, which would
# silently send a malformed tools field.
$tool = '{"type":"function","function":{"name":"get_timer","description":"Set a countdown timer",' +
        '"parameters":{"type":"object","required":["minutes"],"properties":{' +
        '"minutes":{"type":"integer","description":"How many minutes"}}}}}'
$bodyB = '{"model":' + ($MODEL | ConvertTo-Json) + ',"stream":false,"tools":[' + $tool + ']' +
         ',"messages":[{"role":"user","content":"Set a timer for 12 minutes."}]}'
$toolOk = $false
$toolDetail = ''
try {
    $r = Invoke-RestMethod -Uri ($API + '/api/chat') -Method Post -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyB)) -TimeoutSec 180
    $calls = $r.message.tool_calls
    if ($calls) {
        $first = @($calls)[0]
        $toolDetail = [string]$first.function.name + '(' + (($first.function.arguments | ConvertTo-Json -Compress)) + ')'
        $toolOk = ([string]$first.function.name -eq 'get_timer')
    } else {
        $toolDetail = 'no tool_calls; it answered in prose: ' + (([string]$r.message.content) -replace '\s+', ' ')
    }
} catch {
    $toolDetail = 'request failed: ' + $_.Exception.Message
}
Say ('      ' + $toolDetail) 'DarkGray'
if ($toolOk) {
    Say '  [ok] It calls tools correctly.' 'Green'
} else {
    Say '  [!!] Tool calling did not work with this model.' 'Red'
    Say '       She will still chat, but cannot set timers or open apps.' 'Red'
    Say '       Tell me and I will switch the model.' 'Red'
}

Say '  (c) where is it running...' 'DarkGray'
$psOut = & $OLLAMA ps 2>&1
foreach ($l in $psOut) { Say ('      ' + $l) 'DarkGray' }
$onGpu = (($psOut -join ' ') -match '(\d+)%\s*GPU')
if ($onGpu) { Say ('  [ok] Running on the GPU.') 'Green' }
else { Say '  [--] Looks CPU-bound. Usually means VRAM was full when it loaded.' 'DarkYellow' }

# ---------------------------------------------------------------------------
Step 'Step 6 of 6: wiring it up'
# ---------------------------------------------------------------------------

$cfg = @{
    model      = $MODEL
    api        = $API + '/api/chat'
    keepAlive  = '5m'
    toolsWork  = $toolOk
    installedAt = (Get-Date -Format o)
}
try {
    ($cfg | ConvertTo-Json) | Set-Content -Path (Join-Path $Root 'brain-config.json') -Encoding UTF8
    Say '  [ok] brain-config.json written.' 'Green'
} catch {
    Say ('  [--] Could not write brain-config.json: ' + $_.Exception.Message) 'DarkGray'
}

$overlayLive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -and $_.CommandLine -like '*glados.ps1*' })
if ($overlayLive.Count -gt 0) {
    Say ''
    Say '  She is running, so I am not editing her config from out here -' 'DarkYellow'
    Say '  she would overwrite it from memory on exit. Type this in her chat:' 'DarkYellow'
    Say ''
    Say '      /brain ollama' 'DarkYellow'
}

Write-Host ''
Say '  Done.' 'DarkYellow'
Say ''
Say ('  Model:      ' + $MODEL)
Say ('  Endpoint:   ' + $API)
Say  '  VRAM:       released 5 minutes after you stop talking to her'
Say ('  Logs:       ' + $script:LogPath)
Write-Host ''
for ($i = 30; $i -gt 0; $i--) {
    Write-Host ("`r  Closing in " + $i + " seconds...   ") -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
