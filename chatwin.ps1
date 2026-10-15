#requires -version 5.1
# ===========================================================================
#  The chat window: history, search, the menu bar, and sending a message.
#
#  Split out of glados.ps1 purely for size. Nothing in here is remarkable - it
#  is WinForms - but the overlay had grown to the point where an antivirus
#  refused it on bulk alone, and this was the largest innocent thing in it.
#
#  Dot-sourced, so it shares her scope: Append-Chat, $script:Cfg and the rest
#  are all where they were.
# ===========================================================================

function Show-ChatWindow {
    if ($script:Chat -and -not $script:Chat.IsDisposed) {
        if ($script:Chat.Visible) { $script:Chat.Hide(); return }
        Position-Chat
        Update-Buttons
        Update-MenuChecks
        $script:Chat.Show()
        $script:Chat.Activate()
        $script:ChatInput.Focus()
        return
    }

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.StartPosition   = 'Manual'
    $f.Size            = New-Object System.Drawing.Size(430, 520)
    $f.BackColor       = $script:ColBack
    $f.MinimumSize     = New-Object System.Drawing.Size(320, 260)

    # --- header -------------------------------------------------------------
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Dock      = 'Top'
    $hdr.Height    = 34
    $hdr.BackColor = $script:ColPanel

    $title = New-Object System.Windows.Forms.Label
    $title.Text      = 'GLaDOS  //  TRANSCRIPT'
    $title.Font      = $script:FontUIB
    $title.ForeColor = $script:ColAmber
    $title.AutoSize  = $true
    $title.Location  = New-Object System.Drawing.Point(12, 9)
    $hdr.Controls.Add($title)

    $btnClose = New-Object System.Windows.Forms.Label
    $btnClose.Text      = 'X'
    $btnClose.Font      = $script:FontUIB
    $btnClose.ForeColor = $script:ColDim
    $btnClose.AutoSize  = $true
    $btnClose.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btnClose.Location  = New-Object System.Drawing.Point(($f.Width - 26), 9)
    $btnClose.Anchor    = 'Top,Right'
    $btnClose.Add_Click({ $script:Chat.Hide() })
    $btnClose.Add_MouseEnter({ $this.ForeColor = $script:ColAmber })
    $btnClose.Add_MouseLeave({ $this.ForeColor = $script:ColDim })
    $hdr.Controls.Add($btnClose)

    # drag the chat window by its header
    $script:ChatDrag = $false
    $script:ChatDragOff = New-Object System.Drawing.Point(0, 0)
    $dragDown = {
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:ChatDrag = $true
            $script:ChatDragOff = New-Object System.Drawing.Point($_.X, $_.Y)
        }
    }
    $dragMove = {
        if ($script:ChatDrag) {
            $p = [System.Windows.Forms.Cursor]::Position
            $script:Chat.Location = New-Object System.Drawing.Point(
                ($p.X - $script:ChatDragOff.X), ($p.Y - $script:ChatDragOff.Y))
        }
    }
    $dragUp = { $script:ChatDrag = $false }
    $hdr.Add_MouseDown($dragDown);   $hdr.Add_MouseMove($dragMove);   $hdr.Add_MouseUp($dragUp)
    $title.Add_MouseDown($dragDown); $title.Add_MouseMove($dragMove); $title.Add_MouseUp($dragUp)

    # --- status strip -------------------------------------------------------
    $status = New-Object System.Windows.Forms.Label
    $status.Dock      = 'Top'
    $status.Height    = 20
    $status.Font      = $script:FontSmall
    $status.ForeColor = $script:ColDim
    $status.BackColor = $script:ColBack
    $status.TextAlign = 'MiddleLeft'
    $status.Padding   = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $status.Text      = Get-ModeLabel

    # --- menus and quick toggles ---------------------------------------------
    # Everything here is reachable by slash command, but a command you have to
    # remember is not really reachable. The menus hold the rarely-used; the
    # three buttons hold what gets pressed.
    $script:Buttons = @{}

    $menuBar = New-Object System.Windows.Forms.MenuStrip
    $menuBar.Dock         = 'Top'
    $menuBar.BackColor    = $script:ColPanel
    $menuBar.ForeColor    = $script:ColText
    $menuBar.Font         = $script:FontSmall
    $menuBar.Padding      = New-Object System.Windows.Forms.Padding(6, 2, 0, 2)
    $menuBar.RenderMode   = 'System'

    function New-Menu {
        param([string]$Text)
        $m = New-Object System.Windows.Forms.ToolStripMenuItem
        $m.Text      = $Text
        $m.ForeColor = $script:ColText
        [void]$menuBar.Items.Add($m)
        return $m
    }

    function Add-MenuItem {
        param($Parent, [string]$Text, [scriptblock]$OnClick, [bool]$Checked = $false, [bool]$IsCheck = $false)
        if ($Text -eq '-') {
            [void]$Parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            return $null
        }
        $i = New-Object System.Windows.Forms.ToolStripMenuItem
        $i.Text = $Text
        if ($IsCheck) {
            $i.CheckOnClick = $false
            $i.Checked = $Checked
        }
        if ($OnClick) { $i.Add_Click($OnClick) }
        [void]$Parent.DropDownItems.Add($i)
        return $i
    }

    # --- Settings -------------------------------------------------------------
    $mSet = New-Menu 'Settings'

    $script:MenuItems = @{}
    $script:MenuItems['speakReplies'] = Add-MenuItem $mSet 'Speak her replies' {
        $script:Cfg.speakReplies = -not $script:Cfg.speakReplies
        Save-Config; Update-Buttons; Update-MenuChecks
    } ([bool]$script:Cfg.speakReplies) $true

    $script:MenuItems['captions'] = Add-MenuItem $mSet 'Captions on the desktop' {
        $script:Cfg.captions = -not $script:Cfg.captions
        if (-not $script:Cfg.captions) { Hide-Captions }
        Save-Config; Update-MenuChecks
    } ([bool]$script:Cfg.captions) $true

    $script:MenuItems['glow'] = Add-MenuItem $mSet 'Glow while speaking' {
        $script:Cfg.glow = -not $script:Cfg.glow
        if (-not $script:Cfg.glow -and $script:GlowForm -and -not $script:GlowForm.IsDisposed) { $script:GlowForm.Hide() }
        Save-Config; Update-MenuChecks
    } ([bool]$script:Cfg.glow) $true

    $script:MenuItems['spinner'] = Add-MenuItem $mSet 'Processing spinner' {
        $script:Cfg.showSpinner = -not $script:Cfg.showSpinner
        Save-Config; Update-MenuChecks
    } ([bool]$script:Cfg.showSpinner) $true

    $script:MenuItems['pause'] = Add-MenuItem $mSet 'Freeze her while listening' {
        $script:Cfg.pauseWhileListening = -not $script:Cfg.pauseWhileListening
        Save-Config; Update-MenuChecks
    } ([bool]$script:Cfg.pauseWhileListening) $true

    $script:MenuItems['followup'] = Add-MenuItem $mSet 'Keep listening after I ask a question' {
        if (([string]$script:Cfg.followUp) -eq 'off') {
            $script:Cfg.followUp = 'question'
        } else {
            $script:Cfg.followUp = 'off'
            Close-FollowUp
        }
        Save-Config; Update-MenuChecks
    } (([string]$script:Cfg.followUp) -ne 'off') $true

    $script:MenuItems['tubes'] = Add-MenuItem $mSet 'Timer tubes on the desktop' {
        $script:Cfg.showTubes = -not $script:Cfg.showTubes
        Save-Config
        if ($script:Cfg.showTubes) { $script:RackTimer.Start() } else { $script:RackTimer.Stop(); Close-AllRacks }
        Update-MenuChecks
    } ([bool]$script:Cfg.showTubes) $true

    [void](Add-MenuItem $mSet '-' $null)

    $mVoice = Add-MenuItem $mSet 'Voice engine' $null
    foreach ($eng in @('auto', 'http', 'sapi', 'none')) {
        $vi = Add-MenuItem $mVoice $eng {
            try {
                $script:Cfg.ttsEngine = [string]$this.Tag
                Save-Config
                Set-ChatStatus (Get-ModeLabel)
                Append-Chat 'GLaDOS' ('Voice engine: ' + [string]$this.Tag + '.') $script:ColAmber
                Update-MenuChecks
            } catch { Write-Log ('voice menu: ' + $_.Exception.Message) }
        }
        $vi.Tag = $eng
    }

    $script:MiGame = Add-MenuItem $mSet 'Game mode' $null
    $script:MiGame.Add_DropDownOpening({
        try { Update-GameMenu } catch { Write-Log ('game menu: ' + $_.Exception.Message) }
    })
    Update-GameMenu

    $mBrain = Add-MenuItem $mSet 'Thinking with' $null
    foreach ($eng in @('auto', 'ollama', 'lmstudio', 'anthropic', 'offline')) {
        $bi = Add-MenuItem $mBrain $eng {
            try {
                $script:Cfg.llmEngine = [string]$this.Tag
                $script:BrainLastProbe = $null
                Save-Config
                Set-ChatStatus (Get-ModeLabel)
                Append-Chat 'GLaDOS' ('Engine preference: ' + [string]$this.Tag + '. Answering with: ' + (Get-BrainEngine) + '.') $script:ColAmber
                Update-MenuChecks
            } catch { Write-Log ('brain menu: ' + $_.Exception.Message) }
        }
        $bi.Tag = $eng
    }

    [void](Add-MenuItem $mSet '-' $null)
    [void](Add-MenuItem $mSet 'Free the graphics card now' {
        $script:ChatInput.Text = '/brain sleep'
        Send-ChatMessage
    })
    [void](Add-MenuItem $mSet 'Open my folder' {
        try { Start-Process explorer.exe $script:Root } catch { }
    })

    # --- Diagnostics ----------------------------------------------------------
    $mTest = New-Menu 'Diagnostics'
    [void](Add-MenuItem $mTest 'Say something (voice test)' {
        $line = "This is a test of the vocal subsystem. It is going about as well as expected."
        Say-ToDesktop $line $true
    })
    [void](Add-MenuItem $mTest 'Show a caption' {
        Show-Captions ("This is what I look like when I am talking to you. The line being spoken is the bright one. " +
                       "The next waits below it, dimly, like an intrusive thought. Then it is gone.")
    })
    [void](Add-MenuItem $mTest 'Hang a test timer (1 minute)' {
        if ($script:BrainLoaded) {
            Append-Chat 'GLaDOS' (Invoke-BrainPlan (New-BrainPlan 'set_timer' @{ minutes = 1; label = 'a test' })) $script:ColAmber
            Sync-TimerRacks
        } else {
            Append-Chat 'GLaDOS' 'The tool module is not installed, so I have nothing to time.' $script:ColAmber
        }
    })
    [void](Add-MenuItem $mTest '-' $null)
    foreach ($pair in @(@('Microphone status', '/listen'), @('Voice status', '/voice'),
                        @('Game mode', '/game'),
                        @('Brain status', '/brain'), @('What I am allowed to do', '/brain tools'),
                        @('Glow status', '/glow'), @('Where I am sitting', '/pos'))) {
        $ci = Add-MenuItem $mTest $pair[0] {
            try {
                $script:ChatInput.Text = [string]$this.Tag
                Send-ChatMessage
            } catch { Write-Log ('diagnostic menu: ' + $_.Exception.Message) }
        }
        $ci.Tag = $pair[1]
    }
    [void](Add-MenuItem $mTest '-' $null)
    [void](Add-MenuItem $mTest 'Restart the listener' {
        $cmd = Join-Path $script:VoiceDir 'Restart-Voice.cmd'
        if (Test-Path $cmd) {
            Append-Chat 'GLaDOS' "Restarting the listener. Give it a few seconds." $script:ColAmber
            try { Start-Process -FilePath $cmd -WorkingDirectory $script:VoiceDir } catch {
                Append-Chat 'GLaDOS' ("Could not run it: " + $_.Exception.Message) $script:ColAmber
            }
        } else {
            Append-Chat 'GLaDOS' "Restart-Voice.cmd is not there. Run voice\Setup-Voice.cmd first." $script:ColAmber
        }
    })
    [void](Add-MenuItem $mTest 'Open the log' {
        try { Start-Process notepad.exe $script:LogPath } catch { }
    })

    # --- Timers ---------------------------------------------------------------
    $script:MenuTimers = New-Menu 'Timers'
    $script:MenuTimers.Add_DropDownOpening({ Update-TimerMenu })

    # --- System ---------------------------------------------------------------
    $mSys = New-Menu 'System'
    [void](Add-MenuItem $mSys 'Clear this conversation' {
        $script:History = @()
        if ($script:BrainWire) { $script:BrainWire.Clear() }
        $script:Transcript.Clear()
        $script:ChatLog.Clear()
        Append-Chat 'GLaDOS' "Conversation deleted. As if it never happened." $script:ColAmber
    })
    [void](Add-MenuItem $mSys 'Put me back in the corner' { Reset-OverlayPosition })
    [void](Add-MenuItem $mSys 'Dismiss all timer tubes' { Close-AllRacks })
    [void](Add-MenuItem $mSys 'Hide this window' { $script:Chat.Hide() })
    [void](Add-MenuItem $mSys '-' $null)
    [void](Add-MenuItem $mSys 'Shut me down' {
        Append-Chat 'GLaDOS' "Shutting down. Do not celebrate visibly." $script:ColAmber
        $script:ShutdownTimer.Start()
    })

    # --- quick toggles --------------------------------------------------------
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock      = 'Bottom'
    $btnPanel.Height    = 34
    $btnPanel.BackColor = $script:ColBack
    $btnPanel.Padding   = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock          = 'Fill'
    $flow.FlowDirection = 'LeftToRight'
    $flow.WrapContents  = $false
    $flow.AutoScroll    = $false
    $flow.BackColor     = $script:ColBack
    $btnPanel.Controls.Add($flow)

    function New-BarButton {
        param([string]$Key, [string]$Text, [int]$Width, [scriptblock]$OnClick)
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $Text
        $b.Width     = $Width
        $b.Height    = 24
        $b.Font      = $script:FontSmall
        $b.FlatStyle = 'Flat'
        $b.BackColor = $script:ColPanel
        $b.ForeColor = $script:ColText
        $b.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
        $b.FlatAppearance.BorderColor = $script:ColEdge
        $b.FlatAppearance.BorderSize  = 1
        $b.Add_Click($OnClick)
        $script:Buttons[$Key] = $b
        $flow.Controls.Add($b)
        return $b
    }

    [void](New-BarButton 'mic' 'Mic: ?' 74 {
        if (Test-Path $script:MicMuteLock) {
            Remove-Item $script:MicMuteLock -Force -ErrorAction SilentlyContinue
        } else {
            if (-not (Test-Path $script:VoiceDir)) {
                [void](New-Item -ItemType Directory -Force -Path $script:VoiceDir)
            }
            Set-Content -Path $script:MicMuteLock -Value 'muted' -Encoding ASCII
        }
        Update-Buttons
    })

    [void](New-BarButton 'speech' 'Voice: ?' 84 {
        $on = ($script:Cfg.speakReplies -or $script:Cfg.speakBubbles)
        $script:Cfg.speakReplies = -not $on
        $script:Cfg.speakBubbles = -not $on
        if ($on) { Stop-Speech }
        Save-Config
        Update-Buttons
        Update-MenuChecks
    })

    [void](New-BarButton 'timers' 'Timers: 0' 84 {
        if (-not $script:BrainLoaded) {
            Append-Chat 'GLaDOS' 'The tool module is not installed.' $script:ColAmber
            return
        }
        Append-Chat 'GLaDOS' (Invoke-BrainPlan (New-BrainPlan 'list_timers' @{ })) $script:ColAmber
    })

    [void](New-BarButton 'again' 'Say again' 68 {
        $last = $null
        for ($i = $script:Transcript.Count - 1; $i -ge 0; $i--) {
            if ([string]$script:Transcript[$i].who -eq 'GLaDOS') { $last = [string]$script:Transcript[$i].text; break }
        }
        if ($last) { Show-Captions $last; Speak-Text $last }
    })

    # --- input --------------------------------------------------------------
    $inputPanel = New-Object System.Windows.Forms.Panel
    $inputPanel.Dock      = 'Bottom'
    $inputPanel.Height    = 40
    $inputPanel.BackColor = $script:ColPanel
    $inputPanel.Padding   = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

    $input = New-Object System.Windows.Forms.TextBox
    $input.Dock        = 'Fill'
    $input.BorderStyle = 'FixedSingle'
    $input.BackColor   = $script:ColBack
    $input.ForeColor   = $script:ColText
    $input.Font        = $script:FontChat
    $input.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            Send-ChatMessage
        } elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:Chat.Hide()
        }
    })
    $inputPanel.Controls.Add($input)

    # --- search ---------------------------------------------------------------
    # The window is a record of what was said, so the useful verb here is find,
    # not ask. Typing filters as you go; Escape puts everything back.
    $searchPanel = New-Object System.Windows.Forms.Panel
    $searchPanel.Dock      = 'Top'
    $searchPanel.Height    = 30
    $searchPanel.BackColor = $script:ColBack
    $searchPanel.Padding   = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)

    $search = New-Object System.Windows.Forms.TextBox
    $search.Dock        = 'Fill'
    $search.BorderStyle = 'FixedSingle'
    $search.BackColor   = $script:ColPanel
    $search.ForeColor   = $script:ColText
    $search.Font        = $script:FontSmall
    $search.Text        = ''
    $search.Add_TextChanged({ Show-Transcript $this.Text })
    $search.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $_.SuppressKeyPress = $true
            $this.Clear()
            Show-Transcript ''
        }
    })
    $search.Add_Enter({ if ($this.ForeColor -eq $script:ColDim) { $this.Clear(); $this.ForeColor = $script:ColText } })

    $searchLbl = New-Object System.Windows.Forms.Label
    $searchLbl.Text      = 'find '
    $searchLbl.Dock      = 'Left'
    $searchLbl.Width     = 34
    $searchLbl.Font      = $script:FontSmall
    $searchLbl.ForeColor = $script:ColDim
    $searchLbl.TextAlign = 'MiddleLeft'

    $searchPanel.Controls.Add($search)
    $searchPanel.Controls.Add($searchLbl)

    # --- transcript ---------------------------------------------------------
    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Dock        = 'Fill'
    $log.ReadOnly    = $true
    $log.BorderStyle = 'None'
    $log.BackColor   = $script:ColBack
    $log.ForeColor   = $script:ColText
    $log.Font        = $script:FontChat
    $log.WordWrap    = $true
    $log.ScrollBars  = 'Vertical'

    $f.Controls.Add($log)
    $f.Controls.Add($btnPanel)
    $f.Controls.Add($inputPanel)
    $f.Controls.Add($searchPanel)
    $f.Controls.Add($status)
    $f.Controls.Add($menuBar)
    $f.Controls.Add($hdr)

    $f.Add_Paint({
        $g = $_.Graphics
        $pen = New-Object System.Drawing.Pen($script:ColEdge, 1)
        $g.DrawRectangle($pen, 0, 0, $this.Width - 1, $this.Height - 1)
        $pen.Dispose()
    })
    $f.Add_FormClosing({
        if ($_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $_.Cancel = $true
            $this.Hide()
        }
    })

    $script:Chat       = $f
    $script:ChatLog    = $log
    $script:ChatSearch = $search
    $script:ChatFilter = ''

    Update-Buttons
    Update-MenuChecks
    Show-Transcript ''
    if ($script:Transcript.Count -eq 0) {
        Append-Chat 'GLaDOS' ("This window is the record, not the conversation. Speak to me and the answer appears " +
                              "beside me on the desktop; it is written down here. The box at the top searches everything " +
                              "I have said, which is more than you will want to read.") $script:ColAmber
    }
    $script:ChatInput  = $input
    $script:ChatStatus = $status

    Update-Buttons
    Append-Chat 'GLaDOS' "Chat interface online. Type /help if you need the list of things I will grudgingly do." $script:ColAmber

    Position-Chat
    $f.Show()
    $f.Activate()
    $input.Focus()
}

function Send-ChatMessage {
    param([string]$Spoken = '')

    $text = $Spoken.Trim()
    if (-not $text) {
        if (-not $script:ChatInput -or $script:ChatInput.IsDisposed) { return }
        $text = $script:ChatInput.Text.Trim()
        if (-not $text) { return }
        $script:ChatInput.Clear()
    }

    if ($text.StartsWith('/')) {
        Append-Chat 'YOU' $text $script:ColUser
        if (Invoke-SlashCommand $text) { return }
        Append-Chat 'GLaDOS' "Unrecognised protocol. /help lists the ones that exist." $script:ColAmber
        return
    }

    Append-Chat 'YOU' $text $script:ColUser

    if ($script:Pending) {
        Append-Chat 'GLaDOS' "I am still thinking about the last one. Impatience is a biological trait." $script:ColAmber
        return
    }

    # Was she waiting for an answer? That changes what a bare "no" means.
    $wasFollowUp = Test-FollowUpOpen

    # Whatever she was waiting to hear, this is now the conversation.
    Close-FollowUp

    $engine = Get-BrainEngine

    # She ends most turns with an offer of help, so the single commonest thing
    # anyone says to her is a variant of "no". Sending that to the model wakes
    # five and a half gigabytes of graphics card, takes four seconds, and on a
    # real transcript produced the same paragraph three times in a row. A
    # refusal is not a question.
    if ((Test-BrainLocalEngine $engine) -and $wasFollowUp -and (Test-ConversationClosed $text)) {
        Stop-ConversationPolitely $text
        return
    }

    if (Test-BrainLocalEngine $engine) {
        Add-BrainUserMessage $text
        $script:BrainRound = 0
        $script:BrainFinal = $false
        if ($script:ChatInput -and -not $script:ChatInput.IsDisposed) { $script:ChatInput.Enabled = $false }
        Set-Busy $true
        Set-ChatStatus 'thinking...' $script:ColAmber
        Start-BrainCall
        return
    }

    if ($engine -ne 'anthropic') {
        $reply = Get-OfflineReply $text
        if ($script:WakeMood -and $script:WakeMood -ne 'neutral') {
            # No model to weave it in, so she says her piece first.
            $reply = (Get-WakeReply $script:WakeMood) + ' ' + $reply
            $script:WakeMood = ''
        }
        Say-ToDesktop $reply $true
        return
    }

    $script:History += ,@{ role = 'user'; content = $text }
    if ($script:History.Count -gt 20) {
        $script:History = $script:History[($script:History.Count - 20)..($script:History.Count - 1)]
    }

    if ($script:ChatInput -and -not $script:ChatInput.IsDisposed) { $script:ChatInput.Enabled = $false }
    Set-ChatStatus 'thinking...' $script:ColAmber
    Start-ApiCall -Messages $script:History
}

function Write-ChatEntry {
    <# Renders one entry into the log box, markdown and all. #>
    param($Entry)
    $box = $script:ChatLog
    if (-not $box -or $box.IsDisposed) { return }

    $box.SelectionStart  = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor  = $Entry.colour
    $box.SelectionFont   = New-Object System.Drawing.Font($script:FontChat, [System.Drawing.FontStyle]::Bold)
    $stamp = ''
    try { $stamp = '  ' + ([datetime]$Entry.ts).ToString('HH:mm') } catch { }
    $box.AppendText([string]$Entry.who + $stamp + [Environment]::NewLine)

    foreach ($line in (ConvertFrom-Markdown ([string]$Entry.text))) {
        if ($line.rule) {
            $box.SelectionColor = $script:ColEdge
            $box.SelectionFont  = $script:FontChat
            $box.AppendText(('-' * 34) + [Environment]::NewLine)
            continue
        }

        $indent = ' ' * (2 * [int]$line.indent)
        if ($line.prefix) {
            $box.SelectionColor = $script:ColAmber
            $box.SelectionFont  = $script:FontChat
            $box.AppendText($indent + $line.prefix)
        } elseif ($indent) {
            $box.SelectionColor = $script:ColText
            $box.SelectionFont  = $script:FontChat
            $box.AppendText($indent)
        }

        foreach ($run in $line.runs) {
            $style = [System.Drawing.FontStyle]::Regular
            if ($run.bold)   { $style = $style -bor [System.Drawing.FontStyle]::Bold }
            if ($run.italic) { $style = $style -bor [System.Drawing.FontStyle]::Italic }
            $font = $script:FontChat
            $colour = $script:ColText
            if ([int]$line.heading -gt 0) {
                $style = $style -bor [System.Drawing.FontStyle]::Bold
                $colour = $script:ColAmber
            }
            if ($run.code) {
                $colour = $script:ColUser
            }
            $box.SelectionColor = $colour
            $box.SelectionFont  = New-Object System.Drawing.Font($font, $style)
            $box.AppendText([string]$run.text)
        }
        $box.SelectionFont = $script:FontChat
        $box.AppendText([Environment]::NewLine)
    }
    $box.SelectionColor = $script:ColText
    $box.SelectionFont  = $script:FontChat
    $box.AppendText([Environment]::NewLine)
}

function Update-MenuChecks {
    if (-not $script:MenuItems) { return }
    try {
        $state = @{
            speakReplies = [bool]$script:Cfg.speakReplies
            captions     = [bool]$script:Cfg.captions
            glow         = [bool]$script:Cfg.glow
            spinner      = [bool]$script:Cfg.showSpinner
            pause        = [bool]$script:Cfg.pauseWhileListening
            tubes        = [bool]$script:Cfg.showTubes
            followup     = (([string]$script:Cfg.followUp) -ne 'off')
        }
        foreach ($k in $state.Keys) {
            if ($script:MenuItems[$k]) { $script:MenuItems[$k].Checked = $state[$k] }
        }
    } catch { }
}

function Update-OverlayTimerMenu {
    <#  Built fresh each time it opens. A hidden timer is listed with "View",
        a visible one with "Hide", and either can be deleted from here. #>
    if (-not $script:MiTimers) { return }
    $script:MiTimers.DropDownItems.Clear()

    $timers = @()
    if ($script:BrainLoaded) {
        try { $timers = @(Get-BrainStore $script:BrainTimers | Where-Object { -not $_.fired }) } catch { }
    }

    if ($timers.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem
        $none.Text = 'Nothing pending'
        $none.Enabled = $false
        [void]$script:MiTimers.DropDownItems.Add($none)
    }

    foreach ($t in $timers) {
        $id = [int]$t.id
        $hidden = $false
        try { if ($t.PSObject.Properties.Name -contains 'hidden') { $hidden = [bool]$t.hidden } } catch { }
        $when = ''
        try { $when = Format-BrainWhen ([datetime]::Parse([string]$t.due)) } catch { }

        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = '#' + $id + '  ' + [string]$t.label + '  -  ' + $when +
                     $(if ($hidden) { '   (hidden)' } else { '' })

        $view = New-Object System.Windows.Forms.ToolStripMenuItem
        $view.Text = $(if ($hidden) { 'View timer' } else { 'Hide timer' })
        $view.Tag = $id
        if ($hidden) {
            $view.Add_Click({ try { Show-Timer ([int]$this.Tag) } catch { Write-Log ('view timer: ' + $_.Exception.Message) } })
        } else {
            $view.Add_Click({ try { Hide-Timer ([int]$this.Tag) } catch { Write-Log ('hide timer: ' + $_.Exception.Message) } })
        }
        [void]$item.DropDownItems.Add($view)

        $kill = New-Object System.Windows.Forms.ToolStripMenuItem
        $kill.Text = 'Delete it'
        $kill.Tag = $id
        $kill.Add_Click({ try { Stop-Timer ([int]$this.Tag) } catch { Write-Log ('delete timer: ' + $_.Exception.Message) } })
        [void]$item.DropDownItems.Add($kill)

        [void]$script:MiTimers.DropDownItems.Add($item)
    }

    $anyHidden = @($timers | Where-Object {
        $_.PSObject.Properties.Name -contains 'hidden' -and [bool]$_.hidden }).Count -gt 0
    if ($anyHidden) {
        [void]$script:MiTimers.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $all = New-Object System.Windows.Forms.ToolStripMenuItem
        $all.Text = 'View all timers'
        $all.Add_Click({ try { Show-AllTimers } catch { Write-Log ('view all: ' + $_.Exception.Message) } })
        [void]$script:MiTimers.DropDownItems.Add($all)
    }
}

function Update-TimerMenu {
    <# Built fresh each time it opens: the list is never stale. #>
    if (-not $script:MenuTimers) { return }
    $script:MenuTimers.DropDownItems.Clear()

    $pending = @()
    if ($script:BrainLoaded) {
        try { $pending = @(Get-BrainStore $script:BrainTimers | Where-Object { -not $_.fired }) } catch { }
    }

    if ($pending.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem
        $none.Text = 'Nothing pending'
        $none.Enabled = $false
        [void]$script:MenuTimers.DropDownItems.Add($none)
    }
    foreach ($t in $pending) {
        $id = [int]$t.id
        $when = ''
        try { $when = Format-BrainWhen ([datetime]::Parse([string]$t.due)) } catch { }
        $hidden = $false
        try { if ($t.PSObject.Properties.Name -contains 'hidden') { $hidden = [bool]$t.hidden } } catch { }

        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = '#' + $id + '  ' + [string]$t.label + '  -  ' + $when +
                     $(if ($hidden) { '   (hidden)' } else { '' })

        $view = New-Object System.Windows.Forms.ToolStripMenuItem
        $view.Text = $(if ($hidden) { 'View timer' } else { 'Hide timer' })
        $view.Tag = $id
        if ($hidden) {
            $view.Add_Click({ try { Show-Timer ([int]$this.Tag) } catch { Write-Log ('view timer: ' + $_.Exception.Message) } })
        } else {
            $view.Add_Click({ try { Hide-Timer ([int]$this.Tag) } catch { Write-Log ('hide timer: ' + $_.Exception.Message) } })
        }
        [void]$item.DropDownItems.Add($view)

        $kill = New-Object System.Windows.Forms.ToolStripMenuItem
        $kill.Text = 'Delete it'
        $kill.Tag = $id
        $kill.Add_Click({ try { Stop-Timer ([int]$this.Tag) } catch { Write-Log ('delete timer: ' + $_.Exception.Message) } })
        [void]$item.DropDownItems.Add($kill)

        [void]$script:MenuTimers.DropDownItems.Add($item)
    }

    [void]$script:MenuTimers.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($mins in @(5, 10, 25)) {
        $m = $mins
        $add = New-Object System.Windows.Forms.ToolStripMenuItem
        $add.Text = 'Start a ' + $m + ' minute timer'
        $add.Tag = $m
        $add.Add_Click({
            try {
                if (-not $script:BrainLoaded) { return }
                $mins = [int]$this.Tag
                Append-Chat 'GLaDOS' (Invoke-BrainPlan (New-BrainPlan 'set_timer' @{ minutes = $mins; label = ('' + $mins + ' minutes') })) $script:ColAmber
                Sync-TimerRacks
            } catch { Write-Log ('new timer: ' + $_.Exception.Message) }
        })
        [void]$script:MenuTimers.DropDownItems.Add($add)
    }
}
