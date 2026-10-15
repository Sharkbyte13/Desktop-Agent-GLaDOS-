#requires -version 5.1
# ============================================================================
#  Which part of glados.ps1 does your antivirus object to?
#
#  Defender scans the text of a PowerShell script as it loads and refuses the
#  whole file if any of it matches a signature. It does not say which part. So
#  ask it: write pieces of the file to a scratch script and see which pieces
#  come back refused.
#
#  Nothing is executed. Every probe begins with "exit 0", so even a piece that
#  would do something never gets the chance - the scan happens first, which is
#  the entire point.
#
#  Result goes to amsi-probe.txt next to this file.
# ============================================================================

$ErrorActionPreference = 'Continue'
$root  = $PSScriptRoot
$out   = Join-Path $root 'amsi-probe.txt'
$probe = Join-Path $env:TEMP 'glados_amsi_probe.ps1'
$perr  = Join-Path $env:TEMP 'glados_amsi_probe_err.txt'
$lines = New-Object System.Collections.ArrayList

function Say([string]$m) {
    [void]$lines.Add($m)
    Write-Host $m
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$script:Probes = 0

function Test-Blocked {
    <#  True if this text is refused by the scanner. "exit 0" on the first line
        means nothing in it can run either way. #>
    param([string]$Text)
    $script:Probes++
    Set-Content -LiteralPath $probe -Value ("exit 0" + [Environment]::NewLine + $Text) -Encoding UTF8
    Remove-Item -LiteralPath $perr -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $psExe -PassThru -Wait -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                            '-File', ('"' + $probe + '"')) `
            -RedirectStandardError $perr -RedirectStandardOutput ($perr + '.out')
    $err = ''
    try { if (Test-Path -LiteralPath $perr) { $err = Get-Content -LiteralPath $perr -Raw } } catch { }
    if (-not $err) { return $false }
    return ($err -match 'malicious content' -or $err -match 'ScriptContainedMaliciousContent')
}

Say ('AMSI probe - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ''

# --- does the scanner object to any of these files at all? -------------------
Say '== whole files =='
# Every script in the install, not a fixed list: the point of splitting the
# overlay up was that each piece passes on its own, and that is worth checking
# for each piece rather than for the three I happened to think of.
$targets = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -eq 'amsi-probe.ps1' -or $f.Name -eq 'diagnose.ps1') { continue }
    [void]$targets.Add($f.Name)
}
foreach ($f in @('brain\brain.ps1', 'voice\setup_voice.ps1', 'tts\setup_tts.ps1')) {
    if (Test-Path -LiteralPath (Join-Path $root $f)) { [void]$targets.Add($f) }
}
$blockedFiles = New-Object System.Collections.ArrayList
foreach ($n in $targets) {
    $p = Join-Path $root $n
    if (-not (Test-Path -LiteralPath $p)) { Say ('  ' + $n + ': missing'); continue }
    $t = Get-Content -LiteralPath $p -Raw
    if (Test-Blocked $t) {
        Say ('  ' + $n + ': REFUSED')
        [void]$blockedFiles.Add($n)
    } else {
        Say ('  ' + $n + ': allowed')
    }
}

# A control, so a result of "everything is refused" can be told apart from a
# scanner that is refusing everything.
if (Test-Blocked 'Write-Host "hello"') {
    Say ''
    Say '  !! even a one-line script is refused. Something is wrong with the'
    Say '     scanner or the policy on this machine, not with any one file.'
    Set-Content -LiteralPath $out -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
    Write-Host ''
    Write-Host ('Written to ' + $out)
    return
}
Say '  (control: a trivial script is allowed, so the scanner is being selective)'
Say ''

if ($blockedFiles.Count -eq 0) {
    Say 'Nothing is refused. Starting her, to be sure.'
    Say ''
    $so = Join-Path $env:TEMP 'glados_probe_out.txt'
    $se = Join-Path $env:TEMP 'glados_probe_err.txt'
    foreach ($f in @($so, $se)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $proc = $null
    try {
        $proc = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden `
            -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', ('"' + (Join-Path $root 'glados.ps1') + '"')) `
            -RedirectStandardOutput $so -RedirectStandardError $se
    } catch {
        Say ('  could not start her: ' + $_.Exception.Message)
    }
    if ($proc) {
        $alive = $true
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            if ($proc.HasExited) { $alive = $false; break }
        }
        if ($alive) {
            Say ('  SHE IS RUNNING (pid ' + $proc.Id + ') and has been for twenty seconds.')
            Say '  Leaving her up. Quit from the tray if you would rather not.'
        } else {
            Say ('  she exited after about ' + $i + ' seconds')
            $err = ''
            try { if (Test-Path -LiteralPath $se) { $err = Get-Content -LiteralPath $se -Raw } } catch { }
            if ($err) { foreach ($l in ($err -split "`r?`n")) { if ($l.Trim()) { Say ('     ' + $l) } } }
            else { Say '     (nothing on stderr - look at glados.log)' }
        }
    }
    Say ''
    Say '== the last of glados.log =='
    $log = Join-Path $root 'glados.log'
    if (Test-Path -LiteralPath $log) {
        foreach ($l in @(Get-Content -LiteralPath $log -Tail 20 -ErrorAction SilentlyContinue)) { Say ('  ' + $l) }
    }
    Set-Content -LiteralPath $out -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
    Write-Host ''
    Write-Host ('Written to ' + $out)
    Write-Host 'Press any key to close.'
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 20 }
    return
}

# --- narrow it down ----------------------------------------------------------
foreach ($name in $blockedFiles) {
    $path = Join-Path $root $name
    $all  = @(Get-Content -LiteralPath $path)
    Say ('== narrowing ' + $name + ' (' + $all.Count + ' lines) ==')

    $chunks = 24
    $size = [int][Math]::Ceiling($all.Count / $chunks)
    $ranges = New-Object System.Collections.ArrayList
    for ($s = 0; $s -lt $all.Count; $s += $size) {
        $e = [Math]::Min($s + $size - 1, $all.Count - 1)
        [void]$ranges.Add(@{ from = $s; to = $e })
    }

    # Phase A: is any single stretch refused on its own?
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $ranges) {
        $text = ($all[$r.from..$r.to] -join [Environment]::NewLine)
        if (Test-Blocked $text) {
            Say ('  lines ' + ($r.from + 1) + '-' + ($r.to + 1) + ': refused on its own')
            [void]$found.Add($r)
        }
    }

    # Phase B: nothing alone is enough, so the signature needs several pieces
    # together. Take each stretch out of the whole file and see which removal
    # is the one that clears it.
    if ($found.Count -eq 0) {
        Say '  no single stretch is refused by itself - the signature needs more than one part.'
        Say '  taking each stretch out of the whole file instead:'
        foreach ($r in $ranges) {
            $keep = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $all.Count; $i++) {
                if ($i -ge $r.from -and $i -le $r.to) { continue }
                [void]$keep.Add($all[$i])
            }
            if (-not (Test-Blocked ($keep.ToArray() -join [Environment]::NewLine))) {
                Say ('  removing lines ' + ($r.from + 1) + '-' + ($r.to + 1) + ' CLEARS it')
                [void]$found.Add($r)
            }
        }
    }

    if ($found.Count -eq 0) {
        Say '  could not localise it. The signature is spread across the file.'
        continue
    }

    # Phase C: shrink the first hit until it is as small as it will go.
    $r = $found[0]
    $from = $r.from
    $to   = $r.to
    $alone = Test-Blocked (($all[$from..$to]) -join [Environment]::NewLine)
    if ($alone) {
        Say ('  shrinking lines ' + ($from + 1) + '-' + ($to + 1) + '...')
        $changed = $true
        while ($changed -and ($to - $from) -gt 2) {
            $changed = $false
            $mid = [int](($from + $to) / 2)
            if (Test-Blocked (($all[$from..$mid]) -join [Environment]::NewLine)) {
                $to = $mid; $changed = $true; continue
            }
            if (Test-Blocked (($all[($mid + 1)..$to]) -join [Environment]::NewLine)) {
                $from = $mid + 1; $changed = $true; continue
            }
            # trim the ends one step at a time
            $step = [int][Math]::Max(1, [Math]::Floor(($to - $from) / 8))
            if ((($from + $step) -lt $to) -and
                (Test-Blocked (($all[($from + $step)..$to]) -join [Environment]::NewLine))) {
                $from = $from + $step; $changed = $true; continue
            }
            if ((($to - $step) -gt $from) -and
                (Test-Blocked (($all[$from..($to - $step)]) -join [Environment]::NewLine))) {
                $to = $to - $step; $changed = $true; continue
            }
        }
    }

    Say ''
    Say ('  >>> ' + $name + ' lines ' + ($from + 1) + '-' + ($to + 1) + ' <<<')
    Say ''
    for ($i = $from; $i -le $to; $i++) {
        Say ('  ' + ($i + 1).ToString().PadLeft(6) + ' | ' + $all[$i])
    }
    Say ''
}

Say ('probes run: ' + $script:Probes)
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $perr -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath ($perr + '.out') -Force -ErrorAction SilentlyContinue

Set-Content -LiteralPath $out -Value ($lines.ToArray() -join [Environment]::NewLine) -Encoding UTF8
Write-Host ''
Write-Host ('Written to ' + $out)
Write-Host 'Press any key to close.'
try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 20 }
