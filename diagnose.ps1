#requires -version 5.1
# ============================================================================
#  Why will she not start?
#
#  She is launched hidden, with -NonInteractive, by a VBScript. That is exactly
#  right for an overlay and exactly wrong for finding out why it died: nothing
#  is on screen, nothing is on stderr, and if the failure happens before her
#  logging is set up, nothing is in glados.log either.
#
#  This runs the same file the same way, but keeps what it says. Everything
#  lands in diagnose.txt next to it.
# ============================================================================

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$out  = Join-Path $root 'diagnose.txt'
$lines = New-Object System.Collections.ArrayList

function Say([string]$m) {
    [void]$lines.Add($m)
    Write-Host $m
}

Say ('GLaDOS startup diagnosis - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('folder      : ' + $root)
Say ('powershell  : ' + $PSVersionTable.PSVersion.ToString() + '  (' + $PSVersionTable.PSEdition + ')')
Say ('os          : ' + [System.Environment]::OSVersion.VersionString)
Say ('clr         : ' + [System.Environment]::Version.ToString())
Say ('apartment   : ' + [System.Threading.Thread]::CurrentThread.GetApartmentState())
Say ''

# --- 1. what is actually on disk --------------------------------------------
Say '== the files =='
foreach ($n in @('glados.ps1', 'uilogic.ps1', 'brain\brain.ps1', 'glados.vbs', 'config.json', 'games.json')) {
    $p = Join-Path $root $n
    if (-not (Test-Path -LiteralPath $p)) { Say ('  MISSING   ' + $n); continue }
    $f = Get-Item -LiteralPath $p
    $h = ''
    try { $h = (Get-FileHash -LiteralPath $p -Algorithm MD5).Hash.ToLower() } catch { $h = '(no hash)' }
    $blocked = ''
    try {
        if (Get-Item -LiteralPath $p -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
            $blocked = '  *** BLOCKED (mark of the web) ***'
        }
    } catch { }
    Say ('  {0,-16} {1,9} bytes  {2}  {3}{4}' -f $n, $f.Length, $f.LastWriteTime.ToString('MM-dd HH:mm'), $h, $blocked)
}
Say ''

# --- 2. does 5.1 agree that these are valid PowerShell? ----------------------
# This is the failure that leaves no trace anywhere: a parse error means the
# file never runs at all, so no trap, no try/catch and no log line can help.
Say '== does this PowerShell understand the files =='
foreach ($n in @('uilogic.ps1', 'brain\brain.ps1', 'glados.ps1')) {
    $p = Join-Path $root $n
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $errs = $null
    $toks = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$toks, [ref]$errs)
    } catch {
        Say ('  ' + $n + ': the parser itself threw - ' + $_.Exception.Message)
        continue
    }
    $errs = @($errs)
    if ($errs.Count -eq 0) {
        Say ('  ' + $n + ': parses cleanly')
        continue
    }
    Say ('  ' + $n + ': ' + $errs.Count + ' PARSE ERROR(S)')
    foreach ($e in $errs) {
        Say ('     line ' + $e.Extent.StartLineNumber + ' col ' + $e.Extent.StartColumnNumber + ': ' + $e.Message)
        Say ('       > ' + $e.Extent.Text)
    }
}
Say ''

# --- 3. bytes she cannot read ------------------------------------------------
# A file with no byte-order mark is read as ANSI by 5.1, so anything above 127
# arrives as the wrong character and can break a string or a comment.
Say '== encoding =='
foreach ($n in @('glados.ps1', 'uilogic.ps1', 'brain\brain.ps1')) {
    $p = Join-Path $root $n
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $b = [System.IO.File]::ReadAllBytes($p)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $high = 0
    $ctrl = 0
    foreach ($x in $b) {
        if ($x -gt 127) { $high++ }
        if ($x -lt 9 -or ($x -gt 13 -and $x -lt 32)) { $ctrl++ }
    }
    Say ('  {0,-16} bom={1,-5} non-ascii={2,-5} control-chars={3}' -f $n, $bom, $high, $ctrl)
}
Say ''

# --- 4. the pieces, one at a time --------------------------------------------
Say '== loading the parts =='
$ui = Join-Path $root 'uilogic.ps1'
if (Test-Path -LiteralPath $ui) {
    try {
        . $ui
        Say '  uilogic.ps1: loaded'
        foreach ($fn in @('Get-GameModeState', 'Test-ConversationClosed', 'ConvertFrom-ValveKeyValues',
                          'Select-GameExecutables', 'ConvertTo-GamesJson', 'Get-CaptionFrame')) {
            $have = $null -ne (Get-Command $fn -ErrorAction SilentlyContinue)
            Say ('     ' + $(if ($have) { 'ok     ' } else { 'MISSING' }) + ' ' + $fn)
        }
    } catch {
        Say ('  uilogic.ps1: FAILED - ' + $_.Exception.Message)
        Say ('     at line ' + $_.InvocationInfo.ScriptLineNumber)
    }
}

# The native interop, compiled exactly as she compiles it. 5.1 uses an older
# C# compiler than anything else on the machine, so this is worth its own test.
Say ''
Say '== the native interop =='
try {
    $src = Get-Content -LiteralPath (Join-Path $root 'glados.ps1') -Raw
    $m = [regex]::Match($src, "(?s)Add-Type -ReferencedAssemblies 'System\.Drawing' -TypeDefinition @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) {
        Say '  could not find the Add-Type block in glados.ps1'
    } else {
        try {
            Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition $m.Groups[1].Value -ErrorAction Stop
            Say '  compiled cleanly'
            foreach ($meth in @('UserNotificationState', 'ForegroundProcessId', 'ShowNoActivate', 'SetBitmap')) {
                $have = $null -ne ([GladosNative].GetMethod($meth))
                Say ('     ' + $(if ($have) { 'ok     ' } else { 'MISSING' }) + ' ' + $meth)
            }
        } catch {
            Say ('  DID NOT COMPILE - ' + $_.Exception.Message)
        }
    }
} catch {
    Say ('  could not test it - ' + $_.Exception.Message)
}
Say ''

# --- 5. run her for real and keep what she says ------------------------------
# The whole point. Same switches the launcher uses, minus the hiding, with both
# streams captured. If she dies on startup the reason is in here.
Say '== starting her with the output kept =='
$so = Join-Path $env:TEMP 'glados_start_out.txt'
$se = Join-Path $env:TEMP 'glados_start_err.txt'
foreach ($f in @($so, $se)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$proc = $null
try {
    $proc = Start-Process -FilePath $psExe -PassThru -NoNewWindow `
        -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                        '-File', ('"' + (Join-Path $root 'glados.ps1') + '"')) `
        -RedirectStandardOutput $so -RedirectStandardError $se
} catch {
    Say ('  could not start her at all: ' + $_.Exception.Message)
}

if ($proc) {
    Say ('  started, pid ' + $proc.Id + '. Waiting 20 seconds to see whether she stays up...')
    $alive = $true
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        if ($proc.HasExited) { $alive = $false; break }
    }
    if ($alive) {
        Say '  SHE IS STILL RUNNING after 20 seconds. Whatever killed her before, it is not this.'
        Say '  (Leaving her up. Quit her from the tray if you do not want her.)'
    } else {
        Say ('  SHE EXITED after about ' + $i + ' seconds, exit code ' + $proc.ExitCode)
    }

    foreach ($pair in @(@('stdout', $so), @('stderr', $se))) {
        $label = $pair[0]
        $file  = $pair[1]
        $text = ''
        try { if (Test-Path -LiteralPath $file) { $text = Get-Content -LiteralPath $file -Raw } } catch { }
        if ([string]::IsNullOrWhiteSpace($text)) {
            Say ('  ' + $label + ': (nothing)')
        } else {
            Say ('  ' + $label + ':')
            foreach ($l in ($text -split "`r?`n")) { if ($l.Trim()) { Say ('     ' + $l) } }
        }
    }
}
Say ''

# --- 6. anything she managed to log ------------------------------------------
Say '== the last of glados.log =='
$log = Join-Path $root 'glados.log'
if (Test-Path -LiteralPath $log) {
    $tail = @(Get-Content -LiteralPath $log -Tail 25 -ErrorAction SilentlyContinue)
    if ($tail.Count -eq 0) { Say '  (empty)' }
    foreach ($l in $tail) { Say ('  ' + $l) }
} else {
    Say '  there is no glados.log at all'
}

Set-Content -LiteralPath $out -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
Write-Host ''
Write-Host ('Written to ' + $out)
Write-Host 'Send that file back, or leave it there and I will read it.'
Write-Host ''
Write-Host 'Press any key to close.'
try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 20 }
