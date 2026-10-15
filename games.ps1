#requires -version 5.1
# ===========================================================================
#  Game mode: which game is running, and what to do about it.
#
#  Dot-sourced by glados.ps1, so it shares her scope and can use Write-Log,
#  Append-Chat and the rest. It is a separate file because an antivirus scores
#  a PowerShell script on the whole of its contents at once, and process
#  enumeration, executable paths and a games list are all mildly suspicious on
#  their own. Kept here, they are a small file that passes; folded into the
#  overlay, they were part of what got the overlay refused outright.
#
#  Everything decided here that can be decided without a window lives in
#  uilogic.ps1 and is tested there.
# ===========================================================================


function Get-RunningProcessNames {
    <#  Every process name, once, through the raw .NET call rather than
        Get-Process, which wraps three hundred processes in three hundred
        PSObjects. Names only: reading an executable path costs a permission
        check per process, and this runs on the thread that draws her. #>
    $out = New-Object System.Collections.ArrayList
    $procs = $null
    try { $procs = [System.Diagnostics.Process]::GetProcesses() } catch { return $out.ToArray() }
    foreach ($p in $procs) {
        try { [void]$out.Add([string]$p.ProcessName) } catch { }
        try { $p.Dispose() } catch { }
    }
    return $out.ToArray()
}

function Get-ProcessPath {
    <#  Where one named process is running from, or '' if it will not say.

        Reading a path needs a handle its owner may refuse, so this is expected
        to come back empty for anything running as another user or as a service.
        That is not interesting and is not logged. #>
    param([string]$Name)
    if (-not $Name) { return '' }
    $path = ''
    try {
        foreach ($h in @(Get-Process -Name $Name -ErrorAction SilentlyContinue)) {
            try { $path = [string]$h.Path } catch { $path = '' }
            if ($path) { break }
        }
    } catch { return '' }
    return $path
}

function Read-GamesFile {
    <#  The games list, cached until the file changes. It is read on every tick
        and written rarely, so the tick pays a timestamp check and nothing
        more. #>
    param([bool]$Force = $false)

    $stamp = ''
    try {
        if (Test-Path -LiteralPath $script:GamesPath) {
            $stamp = (Get-Item -LiteralPath $script:GamesPath).LastWriteTimeUtc.Ticks.ToString()
        }
    } catch { }

    if (-not $Force -and $stamp -eq $script:GamesStamp -and $null -ne $script:Games) {
        return $script:Games
    }

    $data = @{ apps = @(); ignored = @() }
    if ($stamp) {
        try {
            $raw = Get-Content -LiteralPath $script:GamesPath -Raw -ErrorAction Stop
            $data = ConvertFrom-GamesJson $raw
        } catch {
            Write-Log ('games.json unreadable: ' + $_.Exception.Message)
        }
    }

    # A scan finishes by writing this file, so a changed timestamp is how she
    # learns it is over. The flag is read and cleared on the tick, which is the
    # only place allowed to say anything in the window.
    if ($script:GameScanning -and $stamp -ne $script:GamesStamp) {
        $script:GameScanning = $false
        $script:GamesJustScanned = @($data.apps).Count
    }

    $script:Games = $data
    $script:GamesStamp = $stamp
    return $data
}

function Save-GamesFile {
    param($Apps, $Ignored)
    try {
        Set-Content -LiteralPath $script:GamesPath -Encoding UTF8 `
            -Value (ConvertTo-GamesJson $Apps $Ignored)
        $script:GamesStamp = ''     # force the next read to pick it up
        return $true
    } catch {
        Write-Log ('could not write games.json: ' + $_.Exception.Message)
        return $false
    }
}

function Add-GameApp {
    <# Put something on the watchlist. Returns the name used, or '' if refused. #>
    param([string]$Exe, [string]$Name = '', [string]$Source = 'manual')

    $exe = ConvertTo-ProcessName $Exe
    if (-not $exe) { return '' }
    if (Test-BannedGameName $exe) {
        Append-Chat 'GLaDOS' ($exe + ' is a launcher, not a game. It sits in the process list all ' +
                              'evening, so I would decide you were playing from the moment you opened ' +
                              'it. No.') $script:ColAmber
        return ''
    }
    if (-not $Name) { $Name = $exe }

    $g = Read-GamesFile $true
    $apps = Merge-GameList @($g.apps) @(@{ exe = $exe; name = $Name; source = $Source }) @()
    # Adding something by hand also un-ignores it.
    $ign = @(@($g.ignored) | Where-Object { (ConvertTo-ProcessName ([string]$_)) -ne $exe })
    [void](Save-GamesFile $apps $ign)
    [void]$script:GameChecked.Add($exe)
    Write-Log ('games list: added ' + $exe + ' (' + $Name + ', ' + $Source + ')')
    return $exe
}

function Deny-GameApp {
    <# Never offer this one again, and take it off the list if it is on it. #>
    param([string]$Exe)

    $exe = ConvertTo-ProcessName $Exe
    if (-not $exe) { return '' }

    $g = Read-GamesFile $true
    $apps = @(@($g.apps) | Where-Object { (ConvertTo-ProcessName ([string]$_.exe)) -ne $exe })
    $ign = New-Object System.Collections.ArrayList
    foreach ($i in @($g.ignored)) {
        $k = ConvertTo-ProcessName ([string]$i)
        if ($k -and $k -ne $exe) { [void]$ign.Add($k) }
    }
    [void]$ign.Add($exe)
    [void](Save-GamesFile $apps $ign.ToArray())
    [void]$script:GameChecked.Add($exe)
    Write-Log ('games list: ignoring ' + $exe)
    return $exe
}

function Update-GameSuggestion {
    <#  The games list only knows what it has been told, so something installed
        outside a launcher would never switch game mode on. She finds those by
        looking at where a running program lives: games sit under steamapps, or
        Epic Games, or XboxGames, or a folder called Games, and almost nothing
        else does.

        This used to ask Windows which window was in front. That took a pair of
        API calls which together are precisely how a keylogger decides whose
        keystrokes it is stealing; Defender read the script, saw the shape, and
        refused to run any of it. A path is a better answer anyway - it catches
        a windowed game, which the old way did not.

        Each name is examined once per session and remembered either way, so a
        long session settles down to doing nothing at all. Offers arrive in the
        window, never out loud: interrupting a match to ask about a filename
        would be worse than the problem it solves. #>
    param($Running)

    if (-not $script:Cfg.gameSuggest) { return }

    $g = Read-GamesFile
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($g.apps))    { [void]$known.Add((ConvertTo-ProcessName ([string]$a.exe))) }
    foreach ($i in @($g.ignored)) { [void]$known.Add((ConvertTo-ProcessName ([string]$i))) }

    foreach ($raw in @($Running)) {
        $n = ConvertTo-ProcessName ([string]$raw)
        if (-not $n) { continue }
        if (-not $script:GameChecked.Add($n)) { continue }   # already looked at it once
        if ($known.Contains($n)) { continue }
        if (Test-BannedGameName $n) { continue }

        $path = Get-ProcessPath $n
        if (-not $path) { continue }
        if (-not (Test-GameRootPath $path)) { continue }

        [void]$script:GamePending.Add($n)
        $where = ''
        try { $where = Split-Path $path -Parent } catch { $where = $path }
        Append-Chat 'SYSTEM' ($n + '.exe is running from ' + $where + ', which looks like a games ' +
                              'folder, and it is not on your list. "/game add ' + $n + '" to count ' +
                              'it, "/game never ' + $n + '" to stop me mentioning it. ' +
                              'Settings > Game mode has both.') $script:ColDim
        Write-Log ('game suggestion: ' + $n + ' at ' + $path)
    }
}

function Start-GameScan {
    <#  Hands the launcher scan to scan-games.ps1, as a separate process.

        It used to run here, on a background runspace inside the overlay. That
        put registry reads of installed software and a recursive walk for
        executables into the same file as everything else, and Defender scores a
        script on the sum of what is in it: glados.ps1 crossed the threshold and
        was refused in full, before a line of it ran. Kept apart, the worst case
        is that the scan is refused and the games list fills up more slowly. #>
    if ($script:GameScanning) { return $false }

    $scanner = Join-Path $script:Root 'scan-games.ps1'
    if (-not (Test-Path -LiteralPath $scanner)) {
        Write-Log 'scan-games.ps1 is not installed; the games list will fill up as you play'
        return $false
    }

    $script:GameScanning = $true
    $script:GameScanStarted = Get-Date
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                            '-File', ('"' + $scanner + '"'),
                            '-Root', ('"' + $script:Root + '"'))
        Write-Log 'game scan started'
        return $true
    } catch {
        $script:GameScanning = $false
        Write-Log ('game scan could not start: ' + $_.Exception.Message)
        return $false
    }
}

function Update-GameMode {
    <#  Runs on the five-second tick.

        The signal is the process list, not the screen: fullscreen said yes to a
        film and no to a windowed game, and neither is what anyone meant. A
        listed game being *running* is the whole test, so alt-tabbing to a
        browser mid-match changes nothing.

        The decision itself lives in uilogic.ps1, where the debounce and the
        announce-once rule can be tested without installing a game. #>
    if (-not $script:BrainLoaded) { return }

    $pref = [string]$script:Cfg.gameMode
    if (-not $pref) { $pref = 'auto' }

    # A scan that never wrote anything must not block the next one forever.
    if ($script:GameScanning -and $script:GameScanStarted -and
        ((Get-Date) - $script:GameScanStarted).TotalSeconds -gt 300) {
        $script:GameScanning = $false
        Write-Log 'game scan gave up: nothing written after five minutes'
    }

    $detected = $false
    $hit = $null
    if ($pref -eq 'auto') {
        $g = Read-GamesFile
        $running = @(Get-RunningProcessNames)

        if ($script:GamesJustScanned -ge 0) {
            $n = [int]$script:GamesJustScanned
            $script:GamesJustScanned = -1
            Append-Chat 'SYSTEM' ('Games list updated: ' + $n + ' executable(s). ' +
                                  '/game list to see them, /game add <name> for anything I missed.') $script:ColDim
        }

        if (@($g.apps).Count -gt 0) {
            $hit = Test-GameProcess $running @($g.apps)
            $detected = ($null -ne $hit)
        }
        # One enumeration per tick, shared. The suggestion pass only looks up a
        # path for a name it has never seen before, so it costs one lookup per
        # new program you ever run, not one per tick.
        try { Update-GameSuggestion $running } catch { Write-Log ('game suggestion failed: ' + $_.Exception.Message) }
    }

    $st = Get-GameModeState -Detected $detected -Active $script:GameActive `
              -Streak $script:GameStreak -Announced $script:GameAnnounced -Preference $pref

    $script:GameStreak = [int]$st.streak
    $wasActive = $script:GameActive
    $script:GameActive = [bool]$st.active

    if ($script:GameActive -ne $wasActive) {
        if ($script:GameActive) {
            $what = 'Something on your games list'
            if ($hit) { $what = [string]$hit.name }
            $script:GamePlaying = $what
            Write-Log ('game mode on (' + $what + '): the model will be unloaded after every answer')
            if ([bool]$st.announce -and $script:Cfg.gameModeSpeak) {
                $script:GameAnnounced = $true
                Say-ToDesktop ($what + ' is running, so I am in game mode. I will hand your ' +
                               'graphics card back after every answer instead of sitting on five and ' +
                               'a half gigabytes of it between questions. Do try to win.') $true
            } else {
                Append-Chat 'SYSTEM' ('Game mode on (' + $what + '). Model unloaded after each answer.') $script:ColDim
            }
        } else {
            Write-Log 'game mode off: back to the normal keep-alive'
            $script:GamePlaying = ''
            $script:UnloadPending = $false
            Append-Chat 'SYSTEM' 'Game mode off. Back to the usual keep-alive.' $script:ColDim
        }
    }

    Complete-PendingUnload
}

function Update-GameMenu {
    <#  Rebuilt every time the submenu opens, because the interesting part is
        what she has noticed since you last looked: an app that went fullscreen
        and is not on the list appears here with one item to accept it and one
        to silence it forever. #>
    if (-not $script:MiGame) { return }
    $script:MiGame.DropDownItems.Clear()

    foreach ($mode in @('auto', 'on', 'off')) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = $mode
        $mi.Tag = $mode
        $mi.CheckOnClick = $false
        $mi.Checked = (([string]$script:Cfg.gameMode) -eq $mode)
        $mi.Add_Click({
            try {
                $script:Cfg.gameMode = [string]$this.Tag
                $script:GameStreak = 0
                Save-Config
                Update-GameMode
                Append-Chat 'GLaDOS' ('Game mode: ' + [string]$this.Tag + '. Currently ' +
                    $(if ($script:GameActive) { 'on - I hand the card back after every answer' }
                      else { 'off - I keep the model warm for ' + (Get-BrainKeepAlive) }) +
                    '.') $script:ColAmber
            } catch { Write-Log ('game menu mode: ' + $_.Exception.Message) }
        })
        [void]$script:MiGame.DropDownItems.Add($mi)
    }

    [void]$script:MiGame.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $count = 0
    try { $count = @((Read-GamesFile).apps).Count } catch { }

    $scan = New-Object System.Windows.Forms.ToolStripMenuItem
    $scan.Text = 'Read my launchers again'
    $scan.Add_Click({
        try {
            if (Start-GameScan) {
                Append-Chat 'GLaDOS' "Reading your launchers. A few seconds." $script:ColAmber
            }
        } catch { Write-Log ('game menu scan: ' + $_.Exception.Message) }
    })
    [void]$script:MiGame.DropDownItems.Add($scan)

    $list = New-Object System.Windows.Forms.ToolStripMenuItem
    $list.Text = 'What counts as a game (' + $count + ')'
    $list.Add_Click({
        try { [void](Invoke-SlashCommand '/game list') } catch { Write-Log ('game menu list: ' + $_.Exception.Message) }
    })
    [void]$script:MiGame.DropDownItems.Add($list)

    $pending = @($script:GamePending)
    if ($pending.Count -gt 0) {
        [void]$script:MiGame.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($p in $pending) {
            $exe = [string]$p
            $add = New-Object System.Windows.Forms.ToolStripMenuItem
            $add.Text = 'Add ' + $exe + '.exe to the games list'
            $add.Tag = $exe
            $add.Add_Click({
                try {
                    $e = [string]$this.Tag
                    if (Add-GameApp $e $e 'noticed') {
                        [void]$script:GamePending.Remove($e)
                        Update-GameMode
                        Append-Chat 'GLaDOS' ($e + '.exe is on the list.') $script:ColAmber
                    }
                } catch { Write-Log ('game menu add: ' + $_.Exception.Message) }
            })
            [void]$script:MiGame.DropDownItems.Add($add)

            $no = New-Object System.Windows.Forms.ToolStripMenuItem
            $no.Text = 'Never ask about ' + $exe + '.exe'
            $no.Tag = $exe
            $no.Add_Click({
                try {
                    $e = [string]$this.Tag
                    [void](Deny-GameApp $e)
                    [void]$script:GamePending.Remove($e)
                    Append-Chat 'GLaDOS' ($e + '.exe will not be mentioned again.') $script:ColAmber
                } catch { Write-Log ('game menu deny: ' + $_.Exception.Message) }
            })
            [void]$script:MiGame.DropDownItems.Add($no)
        }
    }
}
