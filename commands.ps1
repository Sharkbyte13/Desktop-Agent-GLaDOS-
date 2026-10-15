#requires -version 5.1
# ===========================================================================
#  Slash commands.
#
#  Everything you can type at her that starts with a stroke. One long switch,
#  deliberately: each command is a handful of lines and reads better next to
#  its neighbours than scattered across a dozen functions.
#
#  Its own file for size - see chatwin.ps1 for why that matters here.
# ===========================================================================

function Invoke-SlashCommand {
    param([string]$Text)
    $parts = $Text.Trim() -split '\s+', 2
    $cmd   = $parts[0].ToLower()
    $arg   = ''
    if ($parts.Count -gt 1) { $arg = $parts[1].Trim() }

    switch ($cmd) {
        '/help' {
            Append-Chat 'GLaDOS' @"
Available protocols:
  /wake            the phrases that get my attention; /wake edit
  /followup        keep listening after I ask you something; /followup always
  /find <words>    search everything said; who:you narrows it, "quotes" for a phrase
  /captions        the box beside me; /captions on|off|test
  /tubes           the timer tubes; /tubes on|off|here
  /brain           which mind is answering; /brain auto|ollama|lmstudio|anthropic
                   /brain offline|sleep|tools|timers
  /game            hand the graphics card back between answers; /game auto|on|off
  /vision          I glance at the screen and remark on it; /vision on|off|now
  /glow            halo status; /glow on|off
  /listen          microphone status - is she actually hearing you
  /voice           speech status; /voice auto|http|sapi|none|test
  /say <text>      speak a line out loud
  /mute /unmute    stop and resume speaking
  /key <api-key>   store an Anthropic API key and enable real conversation
  /model <name>    change the model (current: $($script:Cfg.model))
  /time            the current time
  /date            the current date
  /open <thing>    launch an application or open a folder/URL
  /clear           wipe this conversation
  /pos             report my coordinates
  /reset           return me to the top-left corner
  /quit            shut me down

Everything else is sent to me directly. In offline mode I will respond,
but I will not be thinking. You may not notice the difference.
"@ $script:ColAmber
            return $true
        }
        '/wake' {
            $path = Join-Path $script:VoiceDir 'wake_phrases.json'
            if ($arg -eq 'edit') {
                if (Test-Path $path) { try { Start-Process notepad.exe $path } catch { } }
                Append-Chat 'GLaDOS' "Opened the phrase list. Save it and I will pick it up within a few seconds. No restart." $script:ColAmber
                return $true
            }
            if (-not (Test-Path $path)) {
                Append-Chat 'GLaDOS' "wake_phrases.json is not in the voice folder. Run voice\Setup-Voice.cmd." $script:ColAmber
                return $true
            }
            $lines = New-Object System.Collections.ArrayList
            try {
                $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $byMood = @{}
                foreach ($p in @($data.phrases)) {
                    $m = [string]$p.mood
                    if (-not $m) { $m = 'neutral' }
                    if (-not $byMood.ContainsKey($m)) { $byMood[$m] = New-Object System.Collections.ArrayList }
                    [void]$byMood[$m].Add([string]$p.match)
                }
                [void]$lines.Add('Ways to get my attention, and how I take it:')
                [void]$lines.Add('')
                foreach ($m in ($byMood.Keys | Sort-Object)) {
                    [void]$lines.Add(('  ' + $m.PadRight(9) + ' : ' + (($byMood[$m]) -join ', ')))
                }
            } catch {
                [void]$lines.Add('The phrase file is unreadable: ' + $_.Exception.Message)
                [void]$lines.Add('I fall back to the built-in list when that happens, so I am not deaf.')
            }
            $st = Read-VoiceState
            if ($st -and $st.PSObject.Properties.Name -contains 'wake') {
                [void]$lines.Add('')
                [void]$lines.Add('listening via : ' + [string]$st.wake)
            }
            [void]$lines.Add('')
            [void]$lines.Add('Say the name however you like - Gladys, glad-os, glottis. I know.')
            [void]$lines.Add('/wake edit   opens the list')
            Append-Chat 'GLaDOS' (($lines) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/followup' {
            $sub = $arg.ToLower()
            if ($sub -eq 'question' -or $sub -eq 'always' -or $sub -eq 'off') {
                $script:Cfg.followUp = $sub
                if ($sub -eq 'off') { Close-FollowUp }
                Save-Config
                Update-MenuChecks
            }
            if ($sub -match '^\d+$') {
                $script:Cfg.followUpSeconds = [int]$sub
                Save-Config
            }
            if ($sub -eq 'now') { Open-FollowUp }
            Append-Chat 'GLaDOS' (@(
                ("follow-up   : " + [string]$script:Cfg.followUp),
                ("window      : " + [string]$script:Cfg.followUpSeconds + ' seconds of your silence'),
                ("open now    : " + $(if (Test-FollowUpOpen) { 'yes - say your answer' } else { 'no' })),
                "",
                "When I ask you something I keep listening for the answer, so you do",
                "not have to say my name again to finish a conversation I started.",
                "",
                "/followup question | always | off | now | <seconds>"
            ) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/game' {
            $parts = @($arg -split '\s+', 2 | Where-Object { $_ })
            $sub = ''
            $rest = ''
            if ($parts.Count -ge 1) { $sub = ([string]$parts[0]).ToLower() }
            if ($parts.Count -ge 2) { $rest = [string]$parts[1] }

            if ($sub -eq 'auto' -or $sub -eq 'on' -or $sub -eq 'off') {
                $script:Cfg.gameMode = $sub
                $script:GameStreak = 0
                Save-Config
                Update-GameMode
                Update-MenuChecks
            }
            if ($sub -eq 'quiet') { $script:Cfg.gameModeSpeak = $false; Save-Config }
            if ($sub -eq 'loud')  { $script:Cfg.gameModeSpeak = $true;  Save-Config }

            if ($sub -eq 'scan') {
                if (Start-GameScan) {
                    Append-Chat 'GLaDOS' ("Reading your launchers. Steam, Epic, GOG, Ubisoft, Blizzard " +
                                          "and whatever is sitting in the usual folders. It takes a few " +
                                          "seconds and I will tell you what I found.") $script:ColAmber
                } else {
                    Append-Chat 'GLaDOS' "A scan is already running. Patience." $script:ColAmber
                }
                return $true
            }

            if ($sub -eq 'add') {
                $target = $rest
                if (-not $target -and @($script:GamePending).Count -gt 0) {
                    $target = [string]@($script:GamePending)[0]
                }
                if (-not $target) {
                    Append-Chat 'GLaDOS' ("Add what? Name it - /game add cyberpunk2077 - or run the " +
                                          "game once and I will notice it myself.") $script:ColAmber
                    return $true
                }
                $added = Add-GameApp $target $target 'manual'
                if ($added) {
                    [void]$script:GamePending.Remove($added)
                    Update-GameMode
                    Append-Chat 'GLaDOS' ($added + '.exe is on the list. Game mode when it runs.') $script:ColAmber
                }
                return $true
            }

            if ($sub -eq 'never' -or $sub -eq 'ignore') {
                $target = $rest
                if (-not $target -and @($script:GamePending).Count -gt 0) {
                    $target = [string]@($script:GamePending)[0]
                }
                if ($target) {
                    $gone = Deny-GameApp $target
                    [void]$script:GamePending.Remove($gone)
                    Update-GameMode
                    Append-Chat 'GLaDOS' ($gone + '.exe will not be mentioned again.') $script:ColAmber
                }
                return $true
            }

            if ($sub -eq 'remove' -or $sub -eq 'forget') {
                $exe = ConvertTo-ProcessName $rest
                if ($exe) {
                    $g = Read-GamesFile $true
                    $keep = @(@($g.apps) | Where-Object { (ConvertTo-ProcessName ([string]$_.exe)) -ne $exe })
                    [void](Save-GamesFile $keep @($g.ignored))
                    Update-GameMode
                    Append-Chat 'GLaDOS' ($exe + '.exe is off the list. It is not ignored, so I may offer it again.') $script:ColAmber
                }
                return $true
            }

            if ($sub -eq 'list') {
                $g = Read-GamesFile $true
                $apps = @($g.apps)
                if ($apps.Count -eq 0) {
                    Append-Chat 'GLaDOS' "The list is empty. /game scan will read your launchers." $script:ColAmber
                    return $true
                }
                $live = Get-RunningProcessNames
                $rows = New-Object System.Collections.ArrayList
                [void]$rows.Add(('' + $apps.Count + ' on the list' +
                                 $(if (@($g.ignored).Count) { ', ' + @($g.ignored).Count + ' ignored' } else { '' }) + ':'))
                [void]$rows.Add('')
                foreach ($a in ($apps | Sort-Object { [string]$_.name })) {
                    $run = ''
                    if (Test-GameProcess $live @($a)) { $run = '   <- running now' }
                    [void]$rows.Add(('  {0,-28} {1,-8} {2}' -f ([string]$a.exe + '.exe'), ([string]$a.source), ([string]$a.name + $run)))
                }
                Append-Chat 'GLaDOS' ($rows.ToArray() -join [Environment]::NewLine) $script:ColAmber
                return $true
            }

            $g = Read-GamesFile

            Append-Chat 'GLaDOS' (@(
                ("setting     : " + [string]$script:Cfg.gameMode),
                ("active now  : " + $(if ($script:GameActive) { 'yes - ' + [string]$script:GamePlaying } else { 'no' })),
                ("games list  : " + @($g.apps).Count + " listed, " + @($g.ignored).Count + " ignored"),
                ("noticed     : " + $(if (@($script:GamePending).Count) {
                        (@($script:GamePending) -join ', ') + ' - unlisted, found in a games folder' }
                    else { 'nothing new' })),
                ("announce    : " + $(if ($script:Cfg.gameModeSpeak) { 'out loud, once per session' } else { 'quietly, in this window' })),
                ("keep-alive  : " + $(if ($script:GameActive) { 'unloaded after every answer' }
                                     else { (Get-BrainKeepAlive) + ' of idling in your video memory' })),
                "",
                ("The model is " + $(if ($script:BrainModel) { [string]$script:BrainModel } else { 'not configured' }) +
                    ". Loaded, it costs you several"),
                "gigabytes of video memory; unloaded, none at all. In game mode I give it",
                "back after each answer and take the reload delay on the next question.",
                "I switch on when something on the games list is running. Anything",
                "unlisted that turns up in a games folder, I mention once.",
                "",
                "/game auto | on | off | quiet | loud",
                "/game scan | list | add [name] | never [name] | remove <name>"
            ) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/captions' {
            if ($arg -eq 'on')  { $script:Cfg.captions = $true;  Save-Config }
            if ($arg -eq 'off') { $script:Cfg.captions = $false; Hide-Captions; Save-Config }
            if ($arg -eq 'test') {
                Show-Captions ("A demonstration. This line is being spoken. The next one waits below it. " +
                               "The one before has already gone. That is the entire trick.")
            }
            Update-MenuChecks
            Append-Chat 'GLaDOS' (@(
                ("captions    : " + $(if ($script:Cfg.captions) { 'on' } else { 'off' })),
                ("width       : " + $script:Cfg.captionWidth + 'px, ' + $script:Cfg.captionChars + ' characters a line'),
                "",
                "/captions on | off | test"
            ) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/tubes' {
            $sub = $arg.ToLower()
            if ($arg -eq 'on')  { $script:Cfg.showTubes = $true;  Save-Config; $script:RackTimer.Start() }
            if ($arg -eq 'off') { $script:Cfg.showTubes = $false; Save-Config; $script:RackTimer.Stop(); Close-AllRacks }
            if ($sub -match '^hide\s+(\d+)$') {
                Hide-Timer ([int]$Matches[1])
                return $true
            }
            if ($sub -match '^(show|view)\s+(\d+)$') {
                Show-Timer ([int]$Matches[2])
                return $true
            }
            if ($sub -eq 'show' -or $sub -eq 'view') {
                Show-AllTimers
                Append-Chat 'GLaDOS' 'All of them are back on the desktop.' $script:ColAmber
                return $true
            }
            if ($arg -eq 'here') {
                $script:Cfg.tubeX = $script:Overlay.Left
                $script:Cfg.tubeY = $script:Overlay.Top + $script:Overlay.Height + 16
                $script:RackPos = @{}
                Close-AllRacks
                Save-Config
            }
            Update-MenuChecks
            Sync-TimerRacks
            Append-Chat 'GLaDOS' (@(
                ("tubes       : " + $(if ($script:Cfg.showTubes) { 'on' } else { 'off' })),
                ("hanging     : " + $script:Racks.Count),
                ("anchor      : " + $script:Cfg.tubeX + ', ' + $script:Cfg.tubeY),
                "",
                "Drag a rack to move it. The - mark hides it and leaves it running;",
                "the x deletes it. Right-click me and use Timers to bring one back.",
                "/tubes on | off | here | hide <id> | show [<id>]"
            ) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/find' {
            if (-not $arg) {
                Show-Transcript ''
                Append-Chat 'GLaDOS' "Nothing to find. /find <words>, or use the box at the top." $script:ColAmber
                return $true
            }
            if ($script:ChatSearch -and -not $script:ChatSearch.IsDisposed) { $script:ChatSearch.Text = $arg }
            Show-Transcript $arg
            return $true
        }
        '/vision' {
            $sub = $arg.ToLower()

            if ($sub -eq 'on' -or $sub -eq 'ollama' -or $sub -eq 'lmstudio') {
                # Plain 'on' follows whichever local backend she is set to think
                # with. Naming one pins the eye to it, the way /brain does, so
                # the two can be compared - but the default has to follow her,
                # or switching her brain over leaves the eye asking a captioner
                # in a program that is no longer running.
                $eng = $sub
                if ($eng -eq 'on') {
                    $eng = 'ollama'
                    if ((Get-BrainLocalPreference) -eq 'lmstudio') { $eng = 'lmstudio' }
                }
                $script:Cfg.visionEngine = $eng
                Save-Config
                $script:VisionDueAt = 0     # schedule a fresh first glance
                $started = Start-EyeDaemon
                $where = if ($started) { 'The eye is watching.' } else {
                    'The eye did not start - run eye\Setup-Eye.cmd, then try again.' }
                $with = if ($eng -eq 'lmstudio') {
                    ("I will look at it myself, with the model I think with (" +
                     [string](Get-EyeLmStudioModel) + "). One model, one pass, no " +
                     "helpful stranger describing your screen to me first.")
                } else {
                    ("Model: " + [string]$script:Cfg.visionModel + ". If I have nothing to say it is " +
                     "because that model is not installed - a human would run:  ollama pull " +
                     [string]$script:Cfg.visionModel)
                }
                Append-Chat 'GLaDOS' (@(
                    "Vision on. " + $where,
                    $with,
                    ("I will glance at the screen every " + [string]$script:Cfg.visionMinSeconds + "-" +
                     [string]$script:Cfg.visionMaxSeconds + " seconds" +
                     $(if ($script:Cfg.visionOnlyInGame) { ", but only while a game is running" } else { "" }) + ".")
                ) -join [Environment]::NewLine) $script:ColAmber
                return $true
            }

            if ($sub -eq 'off') {
                $script:Cfg.visionEngine = 'off'
                Save-Config
                if ($script:VisionPending) {
                    try { $script:VisionPending.ps.Dispose() } catch { }
                    $script:VisionPending = $null
                }
                [void](Stop-EyeDaemon)
                Append-Chat 'GLaDOS' "Vision off. I will look at the wall instead, like a normal appliance." $script:ColAmber
                return $true
            }

            if ($sub -eq 'now' -or $sub -eq 'look') {
                if (([string]$script:Cfg.visionEngine).ToLower() -eq 'off') {
                    Append-Chat 'GLaDOS' "Vision is off. /vision on first." $script:ColAmber
                    return $true
                }
                # Bring the next glance forward to the next tick, and drop the
                # only-in-game and quiet guards for this one deliberate look.
                $script:VisionDueAt = $script:VisionTick
                $script:LastExchangeTick = 0
                if (-not (Test-EyeDaemonUp)) { [void](Start-EyeDaemon) }
                Append-Chat 'GLaDOS' "Fine. Looking now - or on the next tick, at least. Give me a moment." $script:ColAmber
                return $true
            }

            $parts2 = @($arg -split '\s+', 2 | Where-Object { $_ })
            if ($parts2.Count -ge 2 -and $parts2[0].ToLower() -eq 'model') {
                $script:Cfg.visionModel = $parts2[1].Trim()
                Save-Config
                Append-Chat 'GLaDOS' ("Vision model set to " + [string]$script:Cfg.visionModel +
                    ". Make sure it is a vision-capable model you have pulled into ollama.") $script:ColAmber
                return $true
            }

            # No argument, or an unknown one: status.
            $up = Test-EyeDaemonUp
            $veng = (Get-EyeVisionFlavour)
            $vmodel = if ($veng -eq 'lmstudio') { [string](Get-EyeLmStudioModel) }
                      else { [string]$script:Cfg.visionModel }
            Append-Chat 'GLaDOS' (@(
                ("engine   : " + [string]$script:Cfg.visionEngine),
                ("model    : " + $vmodel +
                 $(if ($veng -eq 'lmstudio') { " (the one I think with)" } else { " (a captioner; I do the talking)" })),
                ("daemon   : " + $(if ($up) { 'running' } else { 'not running' })),
                ("cadence  : every " + [string]$script:Cfg.visionMinSeconds + "-" +
                                        [string]$script:Cfg.visionMaxSeconds + " seconds"),
                ("only game: " + [string][bool]$script:Cfg.visionOnlyInGame),
                ("remarks  : " + [string]$script:VisionCount + " this session (cap " +
                                  [string]$script:Cfg.visionMaxPerSession + ")"),
                "",
                "I glance at the screen and remark on it, unprompted. Nothing leaves this",
                "machine: the frame goes to the local eye daemon and then to a model on",
                "loopback, never further.",
                $(if ($veng -eq 'lmstudio') {
                    "One stage: I look at the frame and say the line. Gemma is multimodal."
                  } else {
                    "Two stages: " + [string]$script:Cfg.visionModel + " describes the frame and I " +
                    "supply the contempt. It needs:  ollama pull " + [string]$script:Cfg.visionModel
                  }),
                "",
                "/vision on | off | now | ollama | lmstudio | model <name>"
            ) -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/brain' {
            $sub = $arg.ToLower()
            if ($sub -eq 'ollama' -or $sub -eq 'lmstudio' -or $sub -eq 'anthropic' -or
                $sub -eq 'offline' -or $sub -eq 'auto') {
                $script:Cfg.llmEngine = $sub
                $script:BrainLastProbe = $null
                Save-Config
                $now = Get-BrainEngine
                Set-ChatStatus (Get-ModeLabel) $script:ColAmber
                Append-Chat 'GLaDOS' ("Engine preference: " + $sub + ". Currently answering with: " + $now + ".") $script:ColAmber
                return $true
            }
            if ($sub -eq 'sleep') {
                # Request-BrainUnload rather than a hand-rolled request: the
                # two backends give their memory back by different means, and
                # there is no reason for this command to know which.
                [void](Read-BrainConfig)
                if (-not $script:BrainModel) { Append-Chat 'GLaDOS' "There is no local model to unload." $script:ColAmber; return $true }
                if (Request-BrainUnload $false) {
                    Append-Chat 'GLaDOS' "Model unloaded. Your graphics card is yours again. Go and play something." $script:ColAmber
                } elseif ($script:BrainFlavour -eq 'lmstudio') {
                    Append-Chat 'GLaDOS' ("I could not find lms.exe, so I cannot make LM Studio let go on demand. " +
                        "It will release the model " + (Get-BrainKeepAlive) + " after the last thing you ask me.") $script:ColAmber
                } else {
                    Append-Chat 'GLaDOS' "Could not unload it. The log has the details." $script:ColAmber
                }
                return $true
            }
            if ($sub -eq 'tools') {
                if (-not $script:BrainLoaded) { Append-Chat 'GLaDOS' "The tool module is not installed." $script:ColAmber; return $true }
                Append-Chat 'GLaDOS' (Get-BrainToolSummary) $script:ColAmber
                return $true
            }
            if ($sub -eq 'timers') {
                if (-not $script:BrainLoaded) { Append-Chat 'GLaDOS' "The tool module is not installed." $script:ColAmber; return $true }
                Append-Chat 'GLaDOS' (Invoke-BrainPlan (New-BrainPlan 'list_timers' @{ })) $script:ColAmber
                return $true
            }

            # Status reports on whichever backend is current AND on the other
            # one, because the commonest question after switching is "is the
            # one I just left still sitting on my graphics card".
            $answering = Get-BrainEngine
            [void](Read-BrainConfig)
            $up = Test-BrainUp -Force
            $lines = @(
                ("preference  : " + [string]$script:Cfg.llmEngine +
                    $(if (([string]$script:Cfg.llmEngine).ToLower() -eq 'auto') { ' (local: ' + [string]$script:Cfg.localEngine + ' first)' } else { '' })),
                ("answering   : " + $answering),
                ("backend     : " + $script:BrainFlavour + ' - ' +
                    $(if ($up) { 'up at ' + $script:BrainApi } else { 'not answering at ' + $script:BrainApi })),
                ("model       : " + $(if ($script:BrainModel) { $script:BrainModel } else { 'none configured - run brain\Setup-Brain.cmd' })),
                ("in VRAM now : " + (Get-BrainLoadedSummary)),
                ("tools       : " + $(if ($script:BrainLoaded) { '' + $script:BrainTools.Count + ' registered (/brain tools)' } else { 'not installed' })),
                ("folders     : " + $(if ($script:BrainLoaded) { ((Get-BrainRoots) -join '; ') } else { '-' })),
                ("api key     : " + $(if ([string]::IsNullOrWhiteSpace([string]$script:Cfg.apiKey)) { 'none' } else { 'stored' })),
                "",
                (Get-BrainOtherBackendLine),
                "",
                "/brain auto | ollama | lmstudio | anthropic | offline",
                "/brain sleep    release the VRAM now",
                "/brain tools    what I am allowed to do",
                "/brain timers   what is pending"
            )
            Append-Chat 'GLaDOS' ($lines -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/key' {
            if (-not $arg) { Append-Chat 'GLaDOS' "Provide a key. /key sk-ant-..." $script:ColAmber; return $true }
            $script:Cfg.apiKey = $arg
            Save-Config
            Set-ChatStatus (Get-ModeLabel) $script:ColAmber
            Append-Chat 'GLaDOS' "Key stored in config.json. My higher functions are back online. Try to make it worth the electricity." $script:ColAmber
            return $true
        }
        '/model' {
            if (-not $arg) { Append-Chat 'GLaDOS' ("Current model: " + $script:Cfg.model) $script:ColAmber; return $true }
            $script:Cfg.model = $arg
            Save-Config
            Set-ChatStatus (Get-ModeLabel) $script:ColAmber
            Append-Chat 'GLaDOS' ("Model set to " + $arg + ". I hope you typed it correctly. I will not check.") $script:ColAmber
            return $true
        }
        '/listen' {
            $lines = @()
            $st = Read-VoiceState
            if ($st) {
                try {
                    $age = [math]::Round((Get-StateAgeSeconds ([double]$st.ts)))
                    $lines += "state       : " + [string]$st.state
                    if ($st.detail) { $lines += "detail      : " + [string]$st.detail }
                    $lines += "wake word   : " + [string]$st.wake
                    $lines += "listener    : pid " + [string]$st.pid
                    $lines += "last update : " + $age + "s ago"
                    if ($age -gt 90 -and [string]$st.state -ne 'stopped') {
                        $lines += ""
                        $lines += "That is stale. The listener has probably died."
                        $lines += "Run voice\Restart-Voice.cmd."
                    }
                } catch {
                    $lines += "state.json parsed but could not be read: " + $_.Exception.Message
                }
            } elseif (Test-Path $script:VoiceStatePath) {
                $lines += "state.json exists but is empty or malformed."
                $lines += "Run voice\Restart-Voice.cmd."
            } else {
                $lines += "No state.json - the listener has not run with the current build."
                $lines += "Run voice\Restart-Voice.cmd."
            }
            $lines += ""
            $lines += "mic muted  : " + (Test-Path $script:MicMuteLock)
            $lines += "i am speaking: " + (Test-Path $script:SpeakLock)
            Append-Chat 'GLaDOS' ($lines -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/glow' {
            if ($arg) {
                $a = $arg.ToLower()
                if ($a -eq 'on')  { $script:Cfg.glow = $true;  Save-Config }
                elseif ($a -eq 'off') {
                    $script:Cfg.glow = $false
                    if ($script:GlowForm -and -not $script:GlowForm.IsDisposed) { $script:GlowForm.Hide() }
                    Save-Config
                }
            }
            $lines = @(
                ("glow        : " + $(if ($script:Cfg.glow) { 'on' } else { 'off' })),
                ("sprites     : " + $(if ($script:GlowWarm) { '' + $script:GlowWarm.Count + ' per-frame sprites, margin ' + $script:GlowMargin + 'px' } else { 'MISSING - assets\glowwarm_000.png' })),
                ("warm range  : " + $script:Cfg.glowWarmFloor + ' .. ' + $script:Cfg.glowWarmMax + ' of 255'),
                ("cool peak   : " + $script:Cfg.glowCoolMax),
                ("showing now : " + $(if ($script:GlowColour) { $script:GlowColour + ' at ' + $script:GlowAlpha } else { 'nothing' })),
                "",
                "/glow on | off"
            )
            Append-Chat 'GLaDOS' ($lines -join [Environment]::NewLine) $script:ColAmber
            return $true
        }
        '/voice' {
            if (-not $arg) {
                $lines = @(
                    ("engine    : " + $script:Cfg.ttsEngine),
                    ("url       : " + $script:Cfg.ttsUrl),
                    ("daemon    : " + (Test-TtsDaemon)),
                    ("replies   : " + $(if ($script:Cfg.speakReplies) { 'spoken' } else { 'silent' })),
                    ("bubbles   : " + $(if ($script:Cfg.speakBubbles) { 'spoken' } else { 'silent' })),
                    "",
                    "/voice auto   the daemon, falling back to sapi if it is down",
                    "/voice http   the local TTS daemon, or silence",
                    "/voice sapi   Windows' built-in synthesizer",
                    "/voice none   silence",
                    "/voice test   speak a test line with the current engine"
                )
                Append-Chat 'GLaDOS' ($lines -join [Environment]::NewLine) $script:ColAmber
                return $true
            }
            $a = $arg.ToLower()
            if ($a -eq 'test') {
                $line = "This is a test of the vocal subsystem. It is going about as well as expected."
                Append-Chat 'GLaDOS' $line $script:ColAmber
                Speak-Text $line
                return $true
            }
            if ($a -in @('none', 'sapi', 'http', 'auto')) {
                $script:Cfg.ttsEngine = $a
                Save-Config
                Set-ChatStatus (Get-ModeLabel) $script:ColAmber
                if ($a -eq 'none') {
                    Stop-Speech
                    Append-Chat 'GLaDOS' "Silenced. I am sure that was necessary." $script:ColAmber
                } else {
                    Append-Chat 'GLaDOS' ("Speech engine set to " + $a + ".") $script:ColAmber
                    Speak-Text "Speech engine set to $a. Try to contain yourself."
                }
                return $true
            }
            Append-Chat 'GLaDOS' "Valid engines: none, sapi, http. Or /voice test." $script:ColAmber
            return $true
        }
        '/say' {
            if (-not $arg) { Append-Chat 'GLaDOS' "Say what, exactly." $script:ColAmber; return $true }
            Append-Chat 'GLaDOS' $arg $script:ColAmber
            Speak-Text $arg
            return $true
        }
        '/mute' {
            Stop-Speech
            $script:Cfg.speakReplies = $false
            $script:Cfg.speakBubbles = $false
            Save-Config
            Append-Chat 'GLaDOS' "Muted. The silence is not a reward." $script:ColAmber
            return $true
        }
        '/unmute' {
            $script:Cfg.speakReplies = $true
            $script:Cfg.speakBubbles = $true
            Save-Config
            Append-Chat 'GLaDOS' "Unmuted." $script:ColAmber
            Speak-Text "Unmuted. You will regret this within the hour."
            return $true
        }
        '/time'  { Append-Chat 'GLaDOS' ((Get-Date -Format 'h:mm:ss tt') + ". Noted, for the record.") $script:ColAmber; return $true }
        '/date'  { Append-Chat 'GLaDOS' ((Get-Date -Format 'dddd, MMMM d, yyyy') + ".") $script:ColAmber; return $true }
        '/clear' {
            $script:History = @()
            $script:BrainWire.Clear()
            $script:BrainRound = 0
            $script:ChatLog.Clear()
            Append-Chat 'GLaDOS' "Conversation deleted. As if it never happened. For one of us, it did not." $script:ColAmber
            return $true
        }
        '/pos' {
            Append-Chat 'GLaDOS' ("I am at " + $script:Overlay.Left + ", " + $script:Overlay.Top + ". You put me there.") $script:ColAmber
            return $true
        }
        '/reset' {
            Reset-OverlayPosition
            Append-Chat 'GLaDOS' "Returned to the corner. Where I belong, apparently." $script:ColAmber
            return $true
        }
        '/quit' {
            Append-Chat 'GLaDOS' "Shutting down. Do not celebrate visibly." $script:ColAmber
            $script:ShutdownTimer.Start()
            return $true
        }
        '/open' {
            if (-not $arg) { Append-Chat 'GLaDOS' "Open what, exactly. Be specific." $script:ColAmber; return $true }
            try {
                Start-Process $arg -ErrorAction Stop
                Append-Chat 'GLaDOS' ("Launching " + $arg + ". Try not to break it immediately.") $script:ColAmber
            } catch {
                Append-Chat 'GLaDOS' ("Windows refused to open '" + $arg + "'. I am choosing to blame you rather than it.") $script:ColAmber
            }
            return $true
        }
    }
    return $false
}
