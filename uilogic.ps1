#requires -version 5.1
# ===========================================================================
#  GLaDOS interface logic - no WinForms in this file.
#
#  Markdown parsing, caption line-breaking and timing, and the digits on the
#  tubes. All of it is arithmetic and string work, which means all of it can
#  be tested here rather than discovered by you at two in the morning.
# ===========================================================================

# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

function Get-MarkdownRuns {
    <#  Splits one line into styled runs. Returns a list of
        @{ text; bold; italic; code }. Unmatched markers stay as text: a lone
        asterisk in "2 * 3" is multiplication, not the start of emphasis. #>
    param([string]$Line)

    $runs = New-Object System.Collections.ArrayList
    if ($null -eq $Line) { return $runs }

    $buf = New-Object System.Text.StringBuilder
    $bold = $false
    $italic = $false
    $code = $false

    $flush = {
        if ($buf.Length -gt 0) {
            [void]$runs.Add(@{ text = $buf.ToString(); bold = $bold; italic = $italic; code = $code })
            [void]$buf.Clear()
        }
    }

    $i = 0
    while ($i -lt $Line.Length) {
        $ch = $Line[$i]
        $rest = $Line.Substring($i)

        if ($ch -eq '`') {
            if ($code) {
                & $flush; $code = $false; $i++; continue
            }
            if ($rest.IndexOf('`', 1) -gt 0) {
                & $flush; $code = $true; $i++; continue
            }
        }
        elseif (-not $code -and $rest.StartsWith('**')) {
            if ($bold) {
                & $flush; $bold = $false; $i += 2; continue
            }
            if ($rest.IndexOf('**', 2) -gt 0) {
                & $flush; $bold = $true; $i += 2; continue
            }
        }
        elseif (-not $code -and ($ch -eq '*' -or $ch -eq '_')) {
            # Underscores inside a word are part of the word: file_name.txt.
            $inWord = ($i -gt 0 -and $Line[$i - 1] -match '\w' -and
                       $i + 1 -lt $Line.Length -and $Line[$i + 1] -match '\w')
            if (-not $inWord) {
                if ($italic) {
                    & $flush; $italic = $false; $i++; continue
                }
                if ($rest.IndexOf([string]$ch, 1) -gt 0) {
                    & $flush; $italic = $true; $i++; continue
                }
            }
        }

        [void]$buf.Append($ch)
        $i++
    }
    & $flush
    return $runs
}

function ConvertFrom-Markdown {
    <#  Whole message to renderable lines. Each line is
        @{ prefix; indent; heading; runs }. The chat window walks this and
        sets fonts; nothing here knows what a font is. #>
    param([string]$Text)

    $lines = New-Object System.Collections.ArrayList
    if ($null -eq $Text) { return $lines }

    $fence = $false
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw

        if ($line.TrimStart().StartsWith('```')) {
            $fence = -not $fence
            continue
        }
        if ($fence) {
            [void]$lines.Add(@{
                prefix = ''; indent = 1; heading = 0
                runs = @(@{ text = $line; bold = $false; italic = $false; code = $true })
            })
            continue
        }

        $indent = 0
        $m = [regex]::Match($line, '^(\s*)')
        if ($m.Success) { $indent = [int]([Math]::Floor($m.Groups[1].Value.Replace("`t", '    ').Length / 2)) }
        $body = $line.Trim()

        $heading = 0
        $prefix = ''

        $h = [regex]::Match($body, '^(#{1,4})\s+(.*)$')
        if ($h.Success) {
            $heading = $h.Groups[1].Value.Length
            $body = $h.Groups[2].Value
        }
        else {
            $b = [regex]::Match($body, '^[-*+]\s+(.*)$')
            if ($b.Success) {
                $prefix = '- '
                $body = $b.Groups[1].Value
            }
            else {
                $n = [regex]::Match($body, '^(\d{1,2})[.)]\s+(.*)$')
                if ($n.Success) {
                    $prefix = $n.Groups[1].Value + '. '
                    $body = $n.Groups[2].Value
                }
                else {
                    $q = [regex]::Match($body, '^>\s?(.*)$')
                    if ($q.Success) {
                        $prefix = '| '
                        $body = $q.Groups[1].Value
                    }
                }
            }
        }

        # A horizontal rule is a line, not three dashes read aloud.
        if ($body -match '^([-*_])\1{2,}$') {
            [void]$lines.Add(@{ prefix = ''; indent = 0; heading = 0; rule = $true; runs = @() })
            continue
        }

        [void]$lines.Add(@{
            prefix = $prefix; indent = $indent; heading = $heading
            runs = (Get-MarkdownRuns $body)
        })
    }
    return $lines
}

function ConvertTo-PlainText {
    <# Markdown with the markers taken out, for the captions and for search. #>
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    foreach ($line in (ConvertFrom-Markdown $Text)) {
        if ($line.rule) { continue }
        $s = ''
        foreach ($r in $line.runs) { $s = $s + $r.text }
        $s = ($line.prefix + $s).Trim()
        if ($s) { [void]$out.Add($s) }
    }
    return ($out -join ' ')
}

# ---------------------------------------------------------------------------
# Captions
# ---------------------------------------------------------------------------

function Get-GreedyWrap {
    <#  Words packed into lines of at most $Width characters. No judgement
        about where the breaks land - that is Split-BalancedLine's problem. #>
    param($Words, [int]$Width)

    $out = New-Object System.Collections.ArrayList
    $line = ''
    foreach ($w in @($Words)) {
        if (-not $w) { continue }
        if (-not $line) { $line = [string]$w; continue }
        $try = $line + ' ' + [string]$w
        if ($try.Length -le $Width) {
            $line = $try
        } else {
            [void]$out.Add($line)
            $line = [string]$w
        }
    }
    if ($line) { [void]$out.Add($line) }
    return $out
}

function Split-BalancedLine {
    <#  Wraps one over-long sentence into near-equal lines.

        Filling each line to the brim and starting a new one at the first word
        that does not fit is how the box ended up saying "You're welcome to
        enjoy your brief moment" / "of..." - a full line followed by a scrap.
        Work out how many lines the sentence needs first, then aim every line
        at that share of it, so the break lands somewhere sensible instead of
        wherever the character count happened to run out.

        Aiming exactly at the share is not enough on its own: a sentence two
        characters longer than two lines of it spills a third line holding one
        word. So the aim is widened until the sentence fits in the number of
        lines it was supposed to need, or until it reaches the limit. #>
    param([string]$Text, [int]$MaxChars)

    $s = ([string]$Text).Trim()
    if (-not $s) { return @() }
    if ($MaxChars -lt 12) { $MaxChars = 12 }

    $words = [regex]::Split($s, '\s+')
    $n = [int][Math]::Ceiling($s.Length / [double]$MaxChars)
    if ($n -lt 2) { $n = 2 }
    $target = [int][Math]::Ceiling($s.Length / [double]$n)
    if ($target -gt $MaxChars) { $target = $MaxChars }

    $best = @(Get-GreedyWrap $words $target)
    for ($w = $target + 2; $w -le $MaxChars; $w += 2) {
        if (@($best).Count -le $n) { break }
        $best = @(Get-GreedyWrap $words $w)
    }
    return $best
}

function Split-CaptionLines {
    <#  Breaks a reply into caption-sized lines, preferring to end on a
        sentence so a line does not stop mid-clause while she keeps talking.

        Short sentences are packed together rather than each taking a line of
        its own: "urgency." alone in the middle of the box reads as a fault.
        The box is measured against these lines and sized to them, so a
        generous $MaxChars costs nothing on the lines that come out short. #>
    param([string]$Text, [int]$MaxChars = 84)

    $out = New-Object System.Collections.ArrayList
    $flat = ConvertTo-PlainText $Text
    $flat = [regex]::Replace($flat, '\s+', ' ').Trim()
    if (-not $flat) { return $out }
    if ($MaxChars -lt 12) { $MaxChars = 12 }

    # Sentences first, then wrap any that are still too long. The last line of
    # a wrap stays open so the next short sentence can join it.
    $pending = ''
    foreach ($chunk in [regex]::Split($flat, '(?<=[.!?])\s+')) {
        $s = ([string]$chunk).Trim()
        if (-not $s) { continue }
        if ($s.Length -le $MaxChars) {
            if ($pending -and ($pending.Length + 1 + $s.Length) -le $MaxChars) {
                $pending = $pending + ' ' + $s
            } else {
                if ($pending) { [void]$out.Add($pending) }
                $pending = $s
            }
            continue
        }
        if ($pending) { [void]$out.Add($pending); $pending = '' }
        $pieces = @(Split-BalancedLine $s $MaxChars)
        for ($i = 0; $i -lt $pieces.Count; $i++) {
            if ($i -eq ($pieces.Count - 1)) { $pending = [string]$pieces[$i] }
            else { [void]$out.Add([string]$pieces[$i]) }
        }
    }
    if ($pending) { [void]$out.Add($pending) }

    # A one-word orphan at the end looks like a mistake; glue it back on.
    if ($out.Count -ge 2) {
        $last = [string]$out[$out.Count - 1]
        $prev = [string]$out[$out.Count - 2]
        if ($last.Length -le 8 -and ($prev.Length + $last.Length + 1) -le ($MaxChars + 8)) {
            $out[$out.Count - 2] = $prev + ' ' + $last
            $out.RemoveAt($out.Count - 1)
        }
    }
    return $out
}

function Get-SpeechDurationMs {
    <#  How long she will be talking. The speech envelope knows exactly, when
        the local voice wrote one; otherwise estimate from the text, because a
        caption that finishes early is better than one that never moves. #>
    param([string]$Text, $Envelope)
    if ($Envelope -and $Envelope.bins -and $Envelope.binMs) {
        $count = @($Envelope.bins).Count
        if ($count -gt 0) { return [int]($count * [double]$Envelope.binMs) }
    }
    $chars = 0
    if ($Text) { $chars = $Text.Length }
    return [int](700 + $chars * 62)
}

function Get-CaptionSchedule {
    <#  Gives every line a slice of the total, proportional to its length, with
        a floor so a three-word line does not flash past unread. #>
    param([array]$Lines, [int]$DurationMs, [int]$MinMs = 700)

    $sched = New-Object System.Collections.ArrayList
    $n = @($Lines).Count
    if ($n -eq 0) { return $sched }
    if ($DurationMs -lt ($MinMs * $n)) { $DurationMs = $MinMs * $n }

    $total = 0
    foreach ($l in $Lines) { $total += [Math]::Max(1, ([string]$l).Length) }

    $at = 0
    for ($i = 0; $i -lt $n; $i++) {
        $share = [Math]::Max(1, ([string]$Lines[$i]).Length) / [double]$total
        $span = [int]($DurationMs * $share)
        if ($span -lt $MinMs) { $span = $MinMs }
        if ($i -eq ($n - 1)) { $span = [Math]::Max($MinMs, $DurationMs - $at) }
        [void]$sched.Add(@{ text = [string]$Lines[$i]; start = $at; end = ($at + $span) })
        $at += $span
    }
    return $sched
}

function Get-CaptionFrame {
    <#  What the three slots hold at time t, and how bright each one is.
        Returns @{ index; done; above; aboveAlpha; current; currentAlpha;
                   below; belowAlpha }. #>
    param($Schedule, [int]$ElapsedMs, [int]$FadeMs = 320)

    $frame = @{
        index = -1; done = $false
        above = ''; aboveAlpha = 0
        current = ''; currentAlpha = 0
        below = ''; belowAlpha = 0
    }
    $n = @($Schedule).Count
    if ($n -eq 0) { $frame.done = $true; return $frame }

    $idx = -1
    for ($i = 0; $i -lt $n; $i++) {
        if ($ElapsedMs -ge $Schedule[$i].start -and $ElapsedMs -lt $Schedule[$i].end) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        if ($ElapsedMs -lt $Schedule[0].start) { $idx = 0 }
        else { $frame.done = $true; $frame.index = $n - 1; return $frame }
    }

    $frame.index = $idx
    $into = $ElapsedMs - $Schedule[$idx].start
    if ($into -lt 0) { $into = 0 }

    # The line being spoken rises to full brightness as it starts. It begins
    # at the brightness the waiting line had, so the handover looks like one
    # line lighting up rather than two lines swapping places.
    $ramp = 1.0
    if ($into -lt $FadeMs) { $ramp = 0.62 + 0.38 * ($into / [double]$FadeMs) }
    $frame.current = $Schedule[$idx].text
    $frame.currentAlpha = [int][Math]::Round(255 * $ramp)

    # The line before it drifts up and is gone well before the next change.
    if ($idx -gt 0) {
        $fade = 1.0 - ($into / [double]($FadeMs * 2))
        if ($fade -gt 0) {
            $frame.above = $Schedule[$idx - 1].text
            $frame.aboveAlpha = [int][Math]::Round(130 * $fade)
            # The spoken line is always the brightest thing in the box.
            $cap = $frame.currentAlpha - 40
            if ($frame.aboveAlpha -gt $cap) { $frame.aboveAlpha = [Math]::Max(0, $cap) }
        }
    }

    # The line still to come waits, dim.
    if ($idx -lt ($n - 1)) {
        $frame.below = $Schedule[$idx + 1].text
        $frame.belowAlpha = 85
    }
    return $frame
}

function Get-CaptionRows {
    <# How many slots the box needs: one line needs one, never more than three. #>
    param([int]$LineCount)
    if ($LineCount -le 1) { return 1 }
    if ($LineCount -eq 2) { return 2 }
    return 3
}

function Get-CaptionBoxSize {
    <#  The box fits the words rather than the words rattling around inside a
        fixed rectangle. Width comes from the widest line the caller measured;
        height from how many lines there are to show.

        The caller measures the three lines that are on screen now, not the
        whole reply, so the box follows the text as it flows rather than
        standing at the width of the longest line in something she has not
        said yet. #>
    param([int]$MeasuredPx, [int]$Rows, [int]$MaxWidth = 640, [int]$MinWidth = 180)
    $w = $MeasuredPx + 32
    if ($w -gt $MaxWidth) { $w = $MaxWidth }
    if ($w -lt $MinWidth) { $w = $MinWidth }
    $rows = $Rows
    if ($rows -lt 1) { $rows = 1 }
    if ($rows -gt 3) { $rows = 3 }
    return @{ width = $w; height = (20 + $rows * 32); rows = $rows }
}

function Get-CaptionWidthStep {
    <#  One frame of the box changing width.

        Growing happens at once: easing a grow means the line that needs the
        room renders trimmed to an ellipsis for several frames, which reads as
        a glitch rather than as movement. Shrinking has no such problem, so it
        eases, and the box does not snap narrow the instant a short line comes
        up between two long ones. #>
    param([int]$Current, [int]$Target, [double]$Ease = 0.34, [int]$MinStep = 3)

    if ($Target -ge $Current) { return $Target }
    $delta = $Current - $Target
    if ($delta -le $MinStep) { return $Target }
    $step = [int][Math]::Round($delta * $Ease)
    if ($step -lt $MinStep) { $step = $MinStep }
    return ($Current - $step)
}

function Get-CaptionRowLayout {
    <#  Which slot each line sits in, for a box that may only have one or two.
        With a single row there is nothing above or below to show. #>
    param([int]$Rows)
    if ($Rows -le 1) { return @{ above = -1; current = 12; below = -1 } }
    if ($Rows -eq 2) { return @{ above = -1; current = 12; below = 46 } }
    return @{ above = 12; current = 42; below = 76 }
}

function Get-CaptionHoldState {
    <#  Captions must not start scrolling before she starts talking. The speech
        job needs a moment to synthesise; until its envelope lands, the first
        line sits still. Returns 'hold', 'release' or 'run'. #>
    param([bool]$Waiting, [bool]$Synced, [double]$WaitedMs, [int]$MaxWaitMs = 6000)
    if (-not $Waiting) { return 'run' }
    if ($Synced) { return 'release' }
    if ($WaitedMs -ge $MaxWaitMs) { return 'release' }
    return 'hold'
}

function Test-AsksForInput {
    <#  One sentence: is she asking you for something, or is she just being
        like that?

        She asks rhetorical questions constantly - it is most of her register -
        so the question mark cannot be the test. What matters is whether she
        needs an answer before she can go on: which file, yes or no, how long.
        Those are a short and recognisable list. Everything else, including
        every sardonic aside she ends in a question mark, is her talking.

        Rhetoric is checked first, because "Do you want to know why?" is not a
        question about what you want. #>
    param([string]$Sentence)

    $s = ([string]$Sentence).Trim()
    if (-not $s) { return $false }

    # The shapes her sarcasm takes: a question hung off a statement with an
    # ellipsis or an "or", and tag questions bolted onto the end.
    $rhetoric = "(?i)(^or\b|\.\.\.\s*or\b|\bisn't it\b|\bwasn't it\b|\bdoesn't it\b|\bdon't you think\b|\baren't you\b|\bweren't you\b|\bwho knew\b|\bwhy bother\b|\bimagine that\b|\bdo tell\b|\bdo you want to know\b|\bhow (charming|nice|lovely|surprising|original|brave|touching)\b)"
    if ($s -match $rhetoric) { return $false }

    # Asking you to choose, to confirm, or to supply something she is missing.
    $asks = "(?i)(\bshall i\b|\bshould i\b|\bdo you want\b|\bdo you need\b|\bdid you mean\b|\bwould you like\b|\bwould you prefer\b|\bwhich (one|file|folder|of|is it|do you)\b|\bwhat (do you want|did you want|would you like|should i|did you have in mind)\b|\bhow (long|many|much) (do you|did you|should i|would you)\b|\bwhere (do you want|should i)\b|\bwhen (do you want|should i)\b|\btell me (which|if|when|what|where)\b|\blet me know\b|\bconfirm (that|it|this)\b|\bare you sure\b|\byes or no\b|\bsay the word\b|\bpick one\b)"
    if ($s -match $asks) { return $true }

    return $false
}

function Test-WantsFollowUp {
    <#  Should the microphone stay open after this reply?

        'question' - only when she has actually asked you for something, which
                     is the case that matters: she wants an answer and you
                     should not have to say her name again to give it.
        'always'   - every reply leaves the window open.
        'off'      - never.

        A bare question mark used to be enough. It is not, because she is
        written to be sardonic and lands one in most replies:
        "Timer #1 set, in 25 seconds. Enjoy your brief moment of focus... or is
        that another distraction?" held the microphone open for thirty seconds
        after a job that was already finished, which from the outside is
        indistinguishable from her being stuck waiting. So each sentence is
        judged on whether it asks for something - see Test-AsksForInput.

        A question mark inside something she is quoting back at you is not her
        asking either, so quoted spans come out first. #>
    param([string]$Text, [string]$Mode = 'question')

    $m = ([string]$Mode).ToLower()
    if ($m -eq 'off' -or -not $Text) { return $false }
    if ($m -eq 'always') { return $true }

    $t = ([string]$Text).Trim()
    $t = [regex]::Replace($t, '\s+', ' ')
    if (-not $t) { return $false }

    # Anything she is quoting is not her voice asking.
    $t = [regex]::Replace($t, '"[^"]*"', ' ')
    $t = [regex]::Replace($t, "'[^']{6,}'", ' ')

    # A request anywhere in the reply counts, not only at the end:
    # "Which one? The second is larger." is still her waiting on you.
    foreach ($sentence in [regex]::Split($t, '(?<=[.!?])\s+')) {
        if (Test-AsksForInput $sentence) { return $true }
    }
    return $false
}
function Get-TubeDigits {
    <#  Seconds remaining to the six digits on the tubes, HHMMSS. Past its
        time it holds at zero rather than counting into the negative, which
        would be funny exactly once. #>
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $t = [int][Math]::Floor($Seconds)
    $h = [int][Math]::Floor($t / 3600)
    if ($h -gt 99) { $h = 99; $t = 99 * 3600 + 59 * 60 + 59 }
    $m = [int][Math]::Floor(($t % 3600) / 60)
    $s = [int]($t % 60)
    return ('{0:D2}{1:D2}{2:D2}' -f $h, $m, $s)
}

function Get-TubeLayout {
    <#  Where each sprite goes: six tubes with a separator after the second
        and the fourth. Returns the pieces and the total width. #>
    param([int]$TubeW = 58, [int]$SepW = 20)
    $items = New-Object System.Collections.ArrayList
    $x = 0
    for ($i = 0; $i -lt 6; $i++) {
        [void]$items.Add(@{ kind = 'tube'; slot = $i; x = $x })
        $x += $TubeW
        if ($i -eq 1 -or $i -eq 3) {
            [void]$items.Add(@{ kind = 'sep'; slot = -1; x = $x })
            $x += $SepW
        }
    }
    return @{ items = $items; width = $x }
}

function Get-TubeStackPosition {
    <#  A new tube rack hangs under the last one rather than on top of it. #>
    param([int]$AnchorX, [int]$AnchorY, [int]$Index, [int]$Pitch = 118)
    return @{ x = $AnchorX; y = ($AnchorY + $Index * $Pitch) }
}

function Get-RackCloseRect {
    <#  The dismiss mark, top right of the rack. A layered window cannot hold
        child controls, so the button is painted into the bitmap and the hit
        test lives here where it can be checked without a screen. #>
    param([int]$Width, [int]$Size = 20, [int]$Inset = 3)
    return @{ x = ($Width - $Size - $Inset); y = $Inset; w = $Size; h = $Size }
}

function Get-RackHideRect {
    <#  The hide control, immediately left of the dismiss mark.

        It used to be a round button with a minus sign in it, which is the
        universal symbol for "minimise" and therefore told you nothing about
        what it would actually do to a timer. It is a labelled pill now, wide
        enough to read, which is also a much easier thing to hit. #>
    param([int]$Width, [int]$W = 78, [int]$H = 20, [int]$Inset = 3, [int]$Gap = 6,
          [int]$CloseSize = 20)
    return @{ x = ($Width - $CloseSize - $Inset - $Gap - $W); y = $Inset; w = $W; h = $H }
}

function Get-RackHit {
    <#  Which mark, if either, a click landed on. One function so the drawing
        and the hit test can never disagree about where they are. #>
    param([int]$X, [int]$Y, [int]$Width)
    if (Test-PointInRect $X $Y (Get-RackCloseRect $Width)) { return 'close' }
    if (Test-PointInRect $X $Y (Get-RackHideRect $Width))  { return 'hide' }
    return ''
}

function Test-TimerStale {
    <#  Did this timer come due while the machine was off?

        Recent enough and it fires normally - she was restarted mid-countdown
        and you still want to know. Older than the grace period and its moment
        has passed; announcing it hours late helps nobody. #>
    param($Due, $Now = $null, [int]$GraceSeconds = 120)
    if (-not $Due) { return $false }
    if (-not $Now) { $Now = Get-Date }
    $when = $null
    if ($Due -is [datetime]) { $when = $Due }
    else {
        try { $when = [datetime]::Parse([string]$Due) } catch { return $false }
    }
    return ($when -lt ([datetime]$Now).AddSeconds(-$GraceSeconds))
}

function Test-PointInRect {
    param([int]$X, [int]$Y, $Rect)
    if (-not $Rect) { return $false }
    return ($X -ge [int]$Rect.x -and $X -lt ([int]$Rect.x + [int]$Rect.w) -and
            $Y -ge [int]$Rect.y -and $Y -lt ([int]$Rect.y + [int]$Rect.h))
}

function Test-TubeAlarm {
    <#  A fired rack flashes: on for 600ms, off for 400ms, forever, until it
        is clicked away. Pure so the blink can be tested without waiting. #>
    param([double]$MsSinceFired)
    $cycle = [Math]::Floor($MsSinceFired / 1000.0)
    $into = $MsSinceFired - ($cycle * 1000.0)
    return ($into -lt 600)
}

# ---------------------------------------------------------------------------
# Transcript search
# ---------------------------------------------------------------------------

function Select-Transcript {
    <#  Filters history. Bare words are ANDed, "a phrase" is matched whole, and
        who:glados narrows to one speaker. #>
    param($Entries, [string]$Query)

    $all = @($Entries)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $all }

    $who = ''
    $q = $Query.Trim()
    $m = [regex]::Match($q, '(?i)\bwho:(\w+)')
    if ($m.Success) {
        $who = $m.Groups[1].Value
        $q = $q.Remove($m.Index, $m.Length).Trim()
    }

    $terms = New-Object System.Collections.ArrayList
    foreach ($t in [regex]::Matches($q, '"([^"]+)"|(\S+)')) {
        $v = $t.Groups[1].Value
        if (-not $v) { $v = $t.Groups[2].Value }
        if ($v) { [void]$terms.Add($v) }
    }

    $hits = New-Object System.Collections.ArrayList
    foreach ($e in $all) {
        if ($who -and ([string]$e.who) -notlike ('*' + $who + '*')) { continue }
        $hay = ([string]$e.who + ' ' + [string]$e.text)
        $ok = $true
        foreach ($t in $terms) {
            if ($hay.IndexOf([string]$t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break }
        }
        if ($ok) { [void]$hits.Add($e) }
    }
    # Callers wrap this in @(). A single hit unrolls to a bare hashtable
    # otherwise, and a hashtable's .Count is how many keys it has, which makes
    # for a confusing hour.
    return $hits
}

# ---------------------------------------------------------------------------
# Game mode
# ---------------------------------------------------------------------------

function Get-GameModeState {
    <#  Decides, from the raw fullscreen detector and last tick's state, whether
        game mode should be on. Kept pure so the debounce and the
        announce-once rule can be tested without a graphics card.

        The debounce is deliberately asymmetric. Switching on costs nothing, so
        it happens quickly. Switching off makes her start hoarding video memory
        again, so it waits until you have plainly stopped playing rather than
        alt-tabbed to a browser for ten seconds.

        Returns a hashtable, never an object, because a single-value return
        unrolls and a hashtable's .Count is its key count. Callers read fields. #>
    param(
        [bool]$Detected,
        [bool]$Active,
        [int]$Streak = 0,
        [bool]$Announced = $false,
        [string]$Preference = 'auto',
        [int]$OnTicks = 2,
        [int]$OffTicks = 6
    )

    $pref = ([string]$Preference).ToLower()

    # Forced on or off: the detector is not consulted at all, and being forced
    # on is still worth announcing once so it is never a mystery.
    if ($pref -eq 'on' -or $pref -eq 'off') {
        $want = ($pref -eq 'on')
        return @{
            active   = $want
            streak   = 0
            changed  = ($want -ne $Active)
            announce = ($want -and -not $Active -and -not $Announced)
            forced   = $true
        }
    }

    # The streak counts ticks the detector has agreed with itself, and resets
    # whenever it changes its mind. Anything below the threshold is noise:
    # a loading screen, a video going fullscreen for a moment, alt-tab.
    $streak = $Streak + 1
    if ($Detected -eq $Active) { $streak = 0 }

    $need = $OnTicks
    if ($Active) { $need = $OffTicks }

    $active = $Active
    $changed = $false
    if ($Detected -ne $Active -and $streak -ge $need) {
        $active = $Detected
        $changed = $true
        $streak = 0
    }

    return @{
        active   = $active
        streak   = $streak
        changed  = $changed
        announce = ($changed -and $active -and -not $Announced)
        forced   = $false
    }
}

function Test-ConversationClosed {
    <#  Is this the user declining, rather than asking?

        She ends most turns with an offer of more help, so the commonest thing
        anyone says to her is a variant of "no". Feeding that to an 8B model
        wakes the GPU, costs four seconds, and produced - three times running,
        word for word - the same paragraph about the GPU not being on fire.
        A refusal does not need a language model.

        Deliberately narrow. It only fires on a short utterance that is
        entirely a refusal: "no thanks" closes the conversation, "no, what
        about tomorrow" does not, and anything it is unsure of goes to the
        model as before. #>
    param([string]$Text)

    if ($null -eq $Text) { return $false }
    $t = $Text.ToLower().Trim()
    # Strip surrounding punctuation and collapse runs of spaces.
    $t = [regex]::Replace($t, '[.!?,;:]+$', '')
    $t = [regex]::Replace($t, '^[.!?,;:]+', '')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if (-not $t) { return $false }

    # Six words is generous for "no thank you that will be all".
    if (@($t -split ' ').Count -gt 6) { return $false }

    $patterns = @(
        '^(no|nope|nah|negative)$',
        '^(no|nope|nah)( thanks| thank you| thankyou)$',
        '^(no|nope|nah)?,? ?not (right now|for now|at the moment|currently|just now|now)$',
        '^not (currently|right now|for now|at the moment|just now)$',
        '^(that|thats|that is|that''s) (all|it|everything|enough)( for now| thanks| thank you)?$',
        '^(i am|im|i''m) (good|fine|all set|done|ok|okay)( thanks| thank you| for now)?$',
        '^(we are|were|we''re) (good|done|fine)( thanks| thank you)?$',
        '^(nothing|nothing else|nothing more|nothing for now|nothing right now)$',
        '^(all good|all set|all done|im done|i''m done|done)( thanks| thank you)?$',
        '^(stop|dismissed|never ?mind|forget it|cancel that)$',
        '^(thanks|thank you|ta|cheers)( thats all| that is all| goodnight| good night| bye)?$',
        '^(goodnight|good night|night|bye|goodbye|see you|later)$',
        '^(no|nope|nah)? ?(im|i am|i''m) (good|fine|all set)$'
    )
    foreach ($p in $patterns) {
        if ($t -match $p) { return $true }
    }
    return $false
}

function Test-SameReply {
    <#  Did the model just say the same thing twice?

        Compared on letters and digits only, so a changed comma or a different
        dash does not count as a new thought. It did this three times in a row
        on a real transcript; the TTS cache logged "cache hit" each time, which
        is how we know the strings were identical to the byte. #>
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $na = [regex]::Replace($A.ToLower(), '[^a-z0-9]', '')
    $nb = [regex]::Replace($B.ToLower(), '[^a-z0-9]', '')
    if (-not $na -or -not $nb) { return $false }
    return ($na -eq $nb)
}

# ---------------------------------------------------------------------------
# Knowing a game when she sees one
# ---------------------------------------------------------------------------

function ConvertFrom-ValveKeyValues {
    <#  Valve's KeyValues format, which Steam uses for libraryfolders.vdf and
        for every appmanifest_*.acf. Quoted keys, quoted values, braces for
        nesting, // for comments, backslash escapes inside strings.

        Written as a tokeniser and an explicit stack rather than a pile of
        regexes, because paths in these files are full of backslashes and a
        regex that is nearly right about escaping is a regex that silently
        drops a drive letter. #>
    param([string]$Text)

    $root = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $root }

    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    $key = $null

    $i = 0
    $n = $Text.Length
    $bs = [char]92     # backslash, spelled out so nothing has to escape it

    while ($i -lt $n) {
        $c = $Text[$i]

        # a comment runs to the end of the line
        if ($c -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne [char]10) { $i++ }
            continue
        }

        if ($c -eq '{') {
            $child = @{}
            if ($null -ne $key) {
                $stack.Peek()[$key] = $child
                $key = $null
            }
            $stack.Push($child)
            $i++
            continue
        }

        if ($c -eq '}') {
            $key = $null
            if ($stack.Count -gt 1) { [void]$stack.Pop() }
            $i++
            continue
        }

        if ($c -eq '"') {
            $i++
            $sb = New-Object System.Text.StringBuilder
            while ($i -lt $n -and $Text[$i] -ne '"') {
                if ($Text[$i] -eq $bs -and ($i + 1) -lt $n) {
                    $e = $Text[$i + 1]
                    # Only the escapes Valve actually emits. Anything else keeps
                    # its backslash: a file written by hand with single
                    # separators would otherwise come out as "C:Program Files",
                    # which is a worse answer than being too literal.
                    if ($e -eq 'n')       { [void]$sb.Append([char]10); $i += 2; continue }
                    elseif ($e -eq 't')   { [void]$sb.Append([char]9);  $i += 2; continue }
                    elseif ($e -eq $bs)   { [void]$sb.Append($bs);      $i += 2; continue }
                    elseif ($e -eq '"')   { [void]$sb.Append('"');      $i += 2; continue }
                    else                  { [void]$sb.Append($bs);      $i++;    continue }
                }
                [void]$sb.Append($Text[$i])
                $i++
            }
            $i++
            $val = $sb.ToString()
            if ($null -eq $key) { $key = $val } else { $stack.Peek()[$key] = $val; $key = $null }
            continue
        }

        $i++
    }
    return $root
}

function Get-SteamLibraryPaths {
    <#  Steam keeps its games in several places and only it knows where. The
        modern libraryfolders.vdf nests a "path" under each numbered entry; the
        old one just mapped a number straight to a path. Both still exist on
        machines that have been upgraded for years. #>
    param($Parsed)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Parsed) { return $out.ToArray() }

    $lf = $null
    try { $lf = $Parsed['libraryfolders'] } catch { }
    if ($null -eq $lf) { $lf = $Parsed }
    if ($lf -isnot [hashtable]) { return $out.ToArray() }

    foreach ($k in @($lf.Keys)) {
        $v = $lf[$k]
        if ($v -is [hashtable]) {
            $p = [string]$v['path']
            if ($p) { [void]$out.Add($p) }
        } elseif ("$k" -match '^\d+$') {
            $s = [string]$v
            if ($s) { [void]$out.Add($s) }
        }
    }
    return $out.ToArray()
}

function Get-SteamAppInfo {
    <# One appmanifest: the game's real name and the folder it lives in. #>
    param($Parsed)
    if ($null -eq $Parsed) { return $null }
    $st = $null
    try { $st = $Parsed['AppState'] } catch { }
    if ($st -isnot [hashtable]) { return $null }

    $dir = [string]$st['installdir']
    if (-not $dir) { return $null }
    $name = [string]$st['name']
    if (-not $name) { $name = $dir }
    return @{ name = $name; installdir = $dir; appid = [string]$st['appid'] }
}

function Test-GameExecutable {
    <#  Is this .exe plausibly the game, rather than the wreckage that ships
        beside it?

        Every game folder contains an uninstaller, two redistributables, a
        crash handler and an anti-cheat service. Adding those to a watchlist
        would be merely useless. Adding a *launcher* would be actively bad: a
        launcher sits in the process list all evening, so she would decide you
        were playing a game from the moment you opened Steam until you shut the
        machine down, and hand your video memory back after every sentence for
        the rest of the day.

        Takes the path, not just the name, because _CommonRedist and
        Engine\Binaries\ThirdParty are the giveaway more often than the
        filename is. #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # A leading separator so the first segment is matched like any other, and
    # so a path that begins with the folder name is not a special case.
    $lower = [char]92 + ([string]$Path).ToLower().Replace('/', [char]92).TrimStart([char]92)

    $denyDirs = @(
        '_commonredist', 'redist', 'redistributable', 'directx', 'dotnet', 'vcredist',
        'prerequisites', 'prereq', 'support', 'extras', 'soundtrack', 'artbook',
        'thirdparty', 'crashreportclient', 'easyanticheat', 'battleye', 'anticheat',
        'installers', 'dxsetup', 'servers', 'dedicatedserver', 'dediserver',
        'tools', 'sdk', 'docs'
    )
    foreach ($d in $denyDirs) {
        if ($lower.Contains([char]92 + $d + [char]92)) { return $false }
    }

    # The basename is taken by hand rather than with [System.IO.Path], whose
    # idea of a separator depends on the platform: on anything but Windows it
    # does not treat a backslash as one, so "DediServer\server.exe" comes back
    # whole and every rule below quietly stops matching. The tests run on Linux;
    # she runs on Windows. They have to agree.
    $b = $lower
    $cut = $b.LastIndexOf([char]92)
    if ($cut -ge 0) { $b = $b.Substring($cut + 1) }
    $dot = $b.LastIndexOf('.')
    if ($dot -gt 0) { $b = $b.Substring(0, $dot) }
    if (-not $b) { return $false }
    if ($b.Length -lt 3) { return $false }

    $denyNames = @(
        'unins', 'uninstall', 'setup', 'install', 'redist', 'vcredist', 'vc_redist',
        'dxsetup', 'dxwebsetup', 'directx', 'dotnetfx', 'oalinst', 'physx', 'openal',
        'crashhandler', 'crashreport', 'crashpad', 'crashsender', 'bugreport',
        'errorreport', 'sentry', 'breakpad', 'prereq', 'vcruntime', 'ueprereq',
        'launcher', 'updater', 'update', 'patcher', 'repair', 'activation', 'register',
        'helper', 'service', 'daemon', 'dedicated', 'benchmark', 'diagnostic',
        'config', 'settings', 'setting', 'editor', 'devenv', 'debug', 'profiler',
        'cefprocess', 'subprocess', 'webhelper', 'anticheat', 'battleye', 'beservice',
        'crashrpt', 'reporter', 'cleanup', 'validator', 'downloader', 'bootstrap'
    )
    foreach ($d in $denyNames) { if ($b.Contains($d)) { return $false } }

    # Matched whole, not as a substring: "server.exe" beside a game is the
    # dedicated server, but "Observer.exe" is a game called Observer, and a
    # substring rule cannot tell those apart.
    $denyExact = @('server', 'host', 'client', 'start', 'run', 'play', 'bin', 'exe')
    foreach ($d in $denyExact) { if ($b -eq $d) { return $false } }

    return $true
}

function Get-LauncherProcessNames {
    <#  Things that are never a game, however they were started.

        Two kinds. First the launchers, which sit in the process list all
        evening: if Steam counted, she would decide you were playing from the
        moment you opened it until you shut the machine down, and quietly
        reload an 8B model after every sentence in between.

        Second, and less obvious: software that is *sold on Steam and installed
        into steamapps* but is not a game. Wallpaper Engine is the one that
        caught this out - it lives in steamapps\common like everything else,
        runs from the moment you log in, and is in every other respect
        indistinguishable from a game that you never stop playing. Being in a
        games folder is good evidence. It is not proof. #>
    return @(
        'steam', 'steamwebhelper', 'steamservice', 'gameoverlayui',
        'epicgameslauncher', 'epicwebhelper', 'epiconlineservicesuserhelper',
        'galaxyclient', 'galaxyclienthelper', 'galaxycommunication',
        'origin', 'originwebhelperservice', 'eadesktop', 'eabackgroundservice',
        'upc', 'uplay', 'ubisoftconnect', 'ubisoftgamelauncher',
        'battle.net', 'battle.net helper', 'agent', 'blizzardbrowser',
        'riotclientservices', 'riotclientux', 'riotclientcrashhandler',
        'leagueclient', 'leagueclientux', 'leagueclientuxrender',
        'gamingservices', 'gamebar', 'gamebarftserver', 'xboxappservices',
        'discord', 'discordptb', 'discordcanary', 'obs64', 'obs32',
        'nvcontainer', 'nvidia share', 'nvidia web helper',
        'explorer', 'dwm', 'chrome', 'firefox', 'msedge', 'brave', 'opera',
        'vlc', 'mpc-hc64', 'mpc-hc', 'spotify', 'powershell', 'pwsh',
        'code', 'devenv', 'conhost', 'windowsterminal',

        # Sold on Steam, installed like a game, not a game. All of these run
        # for hours at a time, which is exactly the shape of the mistake.
        'wallpaper32', 'wallpaper64', 'wallpaperservice32', 'wallpaperservice64',
        'wallpaperengine', 'wallpaper engine', 'ui32', 'ui64',
        'vrserver', 'vrmonitor', 'vrcompositor', 'vrdashboard', 'vrwebhelper',
        'vrstartup', 'steamvr', 'steamtours',
        'aseprite', 'blender', 'krita', 'godot', 'unity', 'unityhub',
        'rpcs3', 'cemu', 'dolphin',            # emulators - a launcher, again
        'mediaplayer', 'moviemaker', 'audacity'
    )
}

function Test-BannedGameName {
    <# Is this process name one that must never go on the watchlist? #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $b = ([string]$Name).ToLower()
    if ($b.EndsWith('.exe')) { $b = $b.Substring(0, $b.Length - 4) }
    if (-not $b) { return $true }
    foreach ($l in (Get-LauncherProcessNames)) { if ($b -eq $l) { return $true } }

    # Wallpaper Engine ships several executables - wallpaper64, webwallpaper64,
    # wallpaperservice64 - and named one of them in a log an hour after the
    # first was banned. No game is called anything with "wallpaper" in it.
    if ($b.Contains('wallpaper')) { return $true }

    return $false
}

function ConvertTo-ProcessName {
    <# "Cyberpunk2077.exe", "C:\games\Cyberpunk2077.exe" and "cyberpunk2077"
       are all the same thing to Get-Process. Settle on one spelling. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = ([string]$Value).Trim().Replace('/', [char]92)
    $cut = $v.LastIndexOf([char]92)
    if ($cut -ge 0) { $v = $v.Substring($cut + 1) }
    if ($v.ToLower().EndsWith('.exe')) { $v = $v.Substring(0, $v.Length - 4) }
    return $v.Trim().ToLower()
}

function Merge-GameList {
    <#  Folds newly discovered games into the list already on disk.

        Keeps what is there (the user may have renamed something), skips
        anything they told her never to ask about again, skips launchers, and
        never lets the same executable in twice. Returns a plain array. #>
    param($Existing, $Found, $Ignored)

    $out  = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $skip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($ig in @($Ignored)) {
        $k = ConvertTo-ProcessName ([string]$ig)
        if ($k) { [void]$skip.Add($k) }
    }

    foreach ($set in @(@($Existing), @($Found))) {
        foreach ($e in $set) {
            if ($null -eq $e) { continue }
            $exe = ''
            $name = ''
            $source = ''
            try { $exe = ConvertTo-ProcessName ([string]$e.exe) } catch { }
            if (-not $exe) { continue }
            try { $name = [string]$e.name } catch { }
            try { $source = [string]$e.source } catch { }
            if (-not $name) { $name = $exe }
            if (-not $source) { $source = 'manual' }
            if ($skip.Contains($exe)) { continue }
            if (Test-BannedGameName $exe) { continue }
            if (-not $seen.Add($exe)) { continue }
            [void]$out.Add(@{ exe = $exe; name = $name; source = $source })
        }
    }
    return $out.ToArray()
}

function Test-GameProcess {
    <#  Is one of the listed games running right now?

        Returns the entry that matched, or $null. Comparison is on the process
        name alone: reading every process's executable path costs a permission
        check per process and several hundred milliseconds, on the thread that
        draws her, five times a minute. #>
    param($Running, $Apps)

    $live = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($Running)) {
        $k = ConvertTo-ProcessName ([string]$r)
        if ($k) { [void]$live.Add($k) }
    }
    if ($live.Count -eq 0) { return $null }

    foreach ($a in @($Apps)) {
        if ($null -eq $a) { continue }
        $exe = ''
        try { $exe = ConvertTo-ProcessName ([string]$a.exe) } catch { }
        if (-not $exe) { continue }
        if ($live.Contains($exe)) { return $a }
    }
    return $null
}

function ConvertTo-GamesJson {
    <#  Hand-built, like every other list she writes, because ConvertTo-Json on
        PowerShell 5.1 collapses a one-element array into a bare object. A games
        list with exactly one game in it would read back as something that is
        not a list at all, and the whole thing would quietly stop working - the
        same failure that cost three days over a thirty-second timer. #>
    param($Apps, $Ignored)

    $a = New-Object System.Collections.ArrayList
    foreach ($e in @($Apps)) {
        if ($null -eq $e) { continue }
        $exe = ''
        try { $exe = [string]$e.exe } catch { }
        if (-not $exe) { continue }
        $name = ''
        $src  = ''
        try { $name = [string]$e.name } catch { }
        try { $src  = [string]$e.source } catch { }
        if (-not $name) { $name = $exe }
        if (-not $src)  { $src = 'manual' }
        [void]$a.Add('{"exe":' + ($exe | ConvertTo-Json) +
                     ',"name":' + ($name | ConvertTo-Json) +
                     ',"source":' + ($src | ConvertTo-Json) + '}')
    }

    $g = New-Object System.Collections.ArrayList
    foreach ($i in @($Ignored)) {
        if ($null -eq $i) { continue }
        $s = [string]$i
        if ($s) { [void]$g.Add(($s | ConvertTo-Json)) }
    }

    return ('{"version":1,"apps":[' + ((@($a.ToArray())) -join ',') +
            '],"ignored":[' + ((@($g.ToArray())) -join ',') + ']}')
}

function ConvertFrom-GamesJson {
    <#  The read side. Never throws and never returns $null: an unreadable or
        half-written games list means game mode does nothing, which is a far
        better failure than an overlay that cannot start. #>
    param([string]$Text)

    $empty = @{ apps = @(); ignored = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $empty }

    $o = $null
    try { $o = $Text | ConvertFrom-Json } catch { return $empty }
    if ($null -eq $o) { return $empty }

    $apps = New-Object System.Collections.ArrayList
    $raw = @()
    try { $raw = @($o.apps) } catch { }
    foreach ($e in $raw) {
        if ($null -eq $e) { continue }
        $exe = ''
        try { $exe = ConvertTo-ProcessName ([string]$e.exe) } catch { }
        if (-not $exe) { continue }
        $name = ''
        $src  = ''
        try { $name = [string]$e.name } catch { }
        try { $src  = [string]$e.source } catch { }
        if (-not $name) { $name = $exe }
        if (-not $src)  { $src = 'manual' }

        # Skipped, not deleted. Wallpaper Engine was on a real user's list
        # before it was ever banned, and the fix should take effect the moment
        # they update rather than waiting for something to rewrite the file.
        # Filtering on read is safe; rewriting on read is what emptied
        # timers.json for three days.
        if (Test-BannedGameName $exe) { continue }

        [void]$apps.Add(@{ exe = $exe; name = $name; source = $src })
    }

    $ign = New-Object System.Collections.ArrayList
    $rawi = @()
    try { $rawi = @($o.ignored) } catch { }
    foreach ($i in $rawi) {
        if ($null -eq $i) { continue }
        $k = ConvertTo-ProcessName ([string]$i)
        if ($k) { [void]$ign.Add($k) }
    }

    return @{ apps = $apps.ToArray(); ignored = $ign.ToArray() }
}

function Select-GameExecutables {
    <#  Given every .exe found under one game's folder, decide which of them are
        the game. Separated out so the awkward part - measuring each file
        against the folder it was found in, rather than against its full path -
        is exercised by tests rather than trusted.

        Returns process names, already normalised, at most $Max of them. #>
    param($Files, [string]$Dir, [int]$Max = 6)

    $out = New-Object System.Collections.ArrayList
    if ($Max -le 0) { return $out.ToArray() }

    $root = ''
    if ($Dir) { $root = ([string]$Dir).Replace('/', [char]92).TrimEnd([char]92) }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Files)) {
        if ($out.Count -ge $Max) { break }
        $full = [string]$f
        if (-not $full) { continue }

        # Measure the path *inside* the game. A Steam library that happens to
        # live under D:\Tools would otherwise fail the folder rules and reject
        # every game in it.
        $rel = $full.Replace('/', [char]92)
        if ($root -and $rel.Length -gt $root.Length -and
            $rel.Substring(0, $root.Length) -eq $root) {
            $rel = $rel.Substring($root.Length)
        }

        if (-not (Test-GameExecutable $rel)) { continue }
        $exe = ConvertTo-ProcessName $rel
        if (-not $exe) { continue }
        if (Test-BannedGameName $exe) { continue }
        if (-not $seen.Add($exe)) { continue }
        [void]$out.Add($exe)
    }
    return $out.ToArray()
}

function Test-GameRootPath {
    <#  Does this executable live somewhere games live?

        Used to decide whether a running program is worth offering for the
        games list. It replaced asking Windows which window is in front, which
        needed a pair of API calls that together are indistinguishable from a
        keylogger - Defender refused to run the whole script over it, and was
        entitled to.

        A path is enough. Games sit under a launcher's library folder, and
        nothing else does. #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = ([string]$Path).ToLower().Replace('/', [char]92)

    $markers = @(
        'steamapps', 'epic games', 'gog galaxy', 'gog games', 'goggames',
        'xboxgames', 'riot games', 'ea games', 'origin games', 'ea desktop',
        'ubisoft game launcher', 'ubisoft', 'battle.net', 'blizzard',
        'games', 'gamelibrary', 'my games'
    )
    foreach ($m in $markers) {
        if ($p.Contains([char]92 + $m + [char]92)) { return $true }
    }
    return $false
}


# ---------------------------------------------------------------------------
# Timers: what to call one out loud
# ---------------------------------------------------------------------------

function Test-GenericTimerLabel {
    <#  Did anyone actually say what this timer was for?

        set_timer's label parameter defaults to the word "timer", and a model
        given nothing to work with hands that same word straight back. She then
        announced "Your timer has expired: timer", which is the sound of a
        program reading a variable at someone. Anything on this list counts as
        no label at all, and she says nothing about what it was for. #>
    param([string]$Label)

    $t = ([string]$Label).Trim()
    if (-not $t) { return $true }
    $t = $t.TrimEnd('.', '!', '?').Trim().ToLower()
    $t = $t -replace '^(a|an|the|my|your)\s+', ''
    $t = $t -replace '\s+', ' '

    return (@('timer', 'timers', 'countdown', 'count down', 'alarm', 'reminder',
              'time', 'untitled', 'unnamed', 'no label', 'none', 'null', 'n/a',
              'general', 'default') -contains $t)
}

function Get-TimerExpiryLine {
    <# What she says when one runs out. #>
    param([string]$Label, [string]$Kind = 'timer')

    $named = -not (Test-GenericTimerLabel $Label)
    $label = ([string]$Label).Trim().TrimEnd('.')

    if ([string]$Kind -eq 'reminder') {
        if ($named) { return ('Reminder: ' + $label + '. You asked me to say that. I have said it.') }
        return 'Your reminder, right on time. You never did say what it was for.'
    }
    if ($named) { return ('Your timer has expired: ' + $label + '. Time, unlike you, is reliable.') }
    return 'Your timer has expired. Time, unlike you, is reliable.'
}

function Get-TimerDeletedLines {
    <# The three ways she acknowledges a cancelled timer, named or not. #>
    param([string]$Label, [string]$Tail = '')

    $label = ([string]$Label).Trim().TrimEnd('.')
    if (Test-GenericTimerLabel $Label) {
        return @(
            ('Timer deleted.' + $Tail),
            ('Cancelled.' + $Tail),
            ('Gone. Erased.' + $Tail)
        )
    }
    return @(
        ('Timer deleted: ' + $label + '.' + $Tail),
        ('Cancelled: ' + $label + '.' + $Tail),
        ('Gone. ' + $label + ', erased.' + $Tail)
    )
}

function Get-StaleTimerLine {
    <#  At startup, for the timers that came due while she was off. Naming them
        is only worth the words when the names mean something. #>
    param($Labels)

    $named = New-Object System.Collections.ArrayList
    foreach ($l in @($Labels)) {
        if (Test-GenericTimerLabel ([string]$l)) { continue }
        [void]$named.Add((([string]$l).Trim().TrimEnd('.')))
    }
    $n = @($Labels).Count
    $what = $(if ($n -eq 1) { '1 timer' } else { ('' + $n + ' timers') })
    if ($named.Count -gt 0) {
        return ($what + ' came due while I was not running (' +
                (($named.ToArray()) -join ', ') + '). I have let them go.')
    }
    return ($what + ' came due while I was not running. I have let them go.')
}

function Get-ShowTimerLabel {
    <# The caption on the button under her while timers are hidden. #>
    param([int]$Count)
    if ($Count -le 1) { return 'view timer' }
    return ('view ' + $Count + ' timers')
}


function Test-TranscriptStale {
    <#  Was this transcript queued while she was not running?

        The listener writes what it heard to voice\inbox whether or not the
        overlay is there to read it. A transcript is a live command, not a
        message left on a desk: acting on an hour-old one is how she came up
        after a reinstall, answered four remarks from the previous hour in her
        first second, and finished sitting in a follow-up window instead of
        saying hello.

        A negative age means the two clocks disagree, not that the transcript
        is from the future. Say nothing is wrong and let it through - dropping
        live speech over clock skew is the worse failure. #>
    param([double]$AgeSeconds, [int]$MaxAgeSeconds)

    if ($MaxAgeSeconds -le 0) { return $false }
    if ($AgeSeconds -lt 0)    { return $false }
    return ($AgeSeconds -gt $MaxAgeSeconds)
}

# ---------------------------------------------------------------------------
# Sampling: how adventurous she is allowed to be
# ---------------------------------------------------------------------------

function Format-BrainTemp {
    <#  One temperature, as a string Ollama will accept.

        Two separate hazards, both of which produce a request that fails with
        nothing useful in the log.

        The first is the decimal separator. "$x" on a double uses the current
        culture, so on a machine set to German or French a temperature of 0.9
        renders as "0,9", which lands in the body as {"temperature":0,9} -
        malformed JSON, rejected whole, and the only symptom is that she stops
        answering. Formatted against the invariant culture it is always a dot.

        The second is the value itself. config.json is hand-editable, so this
        has to survive a missing key, an empty string, the word "high", and a
        cheerful 5.0 from someone who wanted more variety. Anything that is not
        a number falls back to the caller's default; anything that is gets
        clamped to 0..Max. Max defaults to 1.5, above which an 8B model stops
        producing sentences; the Anthropic endpoint accepts no more than 1.0
        and rejects the whole request with a 400 if it is given more, so that
        caller passes its own ceiling. #>
    param($Value, [double]$Default = 0.7, [double]$Max = 1.5)

    $t = $Default
    $parsed = 0.0
    # [double]::TryParse with an explicit invariant culture, so a config file
    # written on one machine and read on another means the same thing.
    if ($null -ne $Value -and [double]::TryParse([string]$Value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        $t = $parsed
    }

    if ($Max -le 0) { $Max = 1.5 }
    if ($t -lt 0)    { $t = 0 }
    if ($t -gt $Max) { $t = $Max }

    return $t.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------------------
# The eye: when she is allowed to remark on the screen
# ---------------------------------------------------------------------------

function Get-NextVisionDelay {
    <#  Seconds until the next glance, drawn at random from [Min, Max]. Kept
        here so the cadence can be tested without waiting minutes for a timer,
        and so the one place that decides "how often" is not buried in a tick.

        A random gap, not a fixed one, is the whole point: a remark every five
        minutes on the dot is a metronome you learn to ignore, and worse, it is
        obviously a machine. Min and Max are validated because config.json is
        hand-editable - a swapped pair or a zero should not turn her into a
        chatterbox. #>
    param([double]$Min = 150, [double]$Max = 420)

    if ($Min -lt 15) { $Min = 15 }          # never a firehose, whatever the file says
    if ($Max -lt $Min) { $Max = $Min }
    if ($Max -eq $Min) { return [int]$Min }
    return [int](Get-Random -Minimum ([int]$Min) -Maximum ([int]([Math]::Ceiling($Max)) + 1))
}

function Get-VisionCommentDecision {
    <#  Should she remark on the screen right now? Pure, so every suppression
        rule is a test rather than something you can only find out by playing
        for an hour.

        Returns a hashtable (never a bare value - a single-value return unrolls,
        and .Count on a hashtable is its key count) with .go and .why. .why is
        for the log, so a glance that did not happen still leaves a trail.

        The rules, in the order a "no" is cheapest to decide:
          - the feature is off, or nothing is due yet;
          - she is talking, or you have just said something (do not talk over
            either side of a conversation);
          - she is only meant to speak over a game and none is running;
          - the frame is blank (exclusive fullscreen hands back black) or has
            not changed since her last remark (a menu, a pause, AFK);
          - she has already hit the per-session ceiling.
        Anything that survives all of them is a yes. #>
    param(
        [bool]$Enabled,
        [double]$Now,               # seconds, any monotonic-ish clock
        [double]$DueAt,             # when the next glance is scheduled
        [bool]$Speaking,
        [double]$LastExchangeAt,    # when the user last said something to her
        [double]$QuietSeconds = 30,
        [bool]$OnlyInGame = $true,
        [bool]$GameActive = $false,
        [bool]$Blank = $false,
        [string]$Sig = '',
        [string]$LastSig = '',
        [int]$Count = 0,
        [int]$Cap = 40
    )

    if (-not $Enabled)         { return @{ go = $false; why = 'off' } }
    if ($Now -lt $DueAt)       { return @{ go = $false; why = 'not due' } }
    if ($Cap -gt 0 -and $Count -ge $Cap) { return @{ go = $false; why = 'session cap reached' } }
    if ($Speaking)             { return @{ go = $false; why = 'she is speaking' } }

    if ($QuietSeconds -gt 0 -and $LastExchangeAt -gt 0 -and
        ($Now - $LastExchangeAt) -lt $QuietSeconds) {
        return @{ go = $false; why = 'just spoke with the user' }
    }

    if ($OnlyInGame -and -not $GameActive) {
        return @{ go = $false; why = 'no game running' }
    }

    if ($Blank)                { return @{ go = $false; why = 'blank frame' } }
    if ($Sig -and $Sig -eq $LastSig) {
        return @{ go = $false; why = 'screen unchanged' }
    }

    return @{ go = $true; why = 'ok' }
}

function Test-EyeDescriptionUsable {
    <#  moondream is a 1.8B captioner and mostly reliable, but on a prompt it
        does not like it returns nothing, or a scrap of URN/hex junk
        ("urn:SystemVerilog.org:...", "urn:system.fs.se:8:47:46:..."). Feeding
        that to the second stage produces her confidently riffing on garbage, so
        a caption has to clear a low bar before it is allowed through: some
        length, some words, and mostly letters rather than punctuation and
        digits. Pure, so the junk cases are pinned by tests. #>
    param([string]$Text)

    if ($null -eq $Text) { return $false }
    $t = $Text.Trim()
    if ($t.Length -lt 15) { return $false }
    # A real caption is several words. One long token is not a sentence.
    if (@($t -split '\s+' | Where-Object { $_ }).Count -lt 4) { return $false }
    # The URN / scheme junk it emits when confused.
    if ($t -match '^\s*urn:') { return $false }
    if ($t -match '^[a-z0-9]+:[a-z0-9]+') { return $false }
    # Mostly letters and spaces? Count what is neither; if a third or more of
    # the text is digits and punctuation it is not prose.
    $letters = ([regex]::Matches($t, '[A-Za-z ]')).Count
    if ($letters -lt ($t.Length * 0.6)) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Local brain: the two backends, and everything that differs between them
#
# She can think with Ollama or with LM Studio. They do the same job and
# disagree about almost every detail of how to ask for it, so the
# disagreements live here - pure, and pinned by tools\test_brain_wire.ps1 -
# instead of being scattered through glados.ps1 as inline branches.
#
#   'ollama'   /api/chat, sampling nested under "options", keep_alive as a
#              duration string, tool results keyed by tool_name.
#   'lmstudio' the OpenAI shape: /v1/chat/completions, sampling at the top
#              level, ttl in whole seconds, tool results keyed by
#              tool_call_id, and tool arguments that arrive as a string.
#
# Adding a third would mean a branch in each of these functions and nothing
# else, which is the point of them being here.
# ---------------------------------------------------------------------------

function ConvertTo-BrainSeconds {
    <#  An Ollama duration string as whole seconds, for LM Studio's ttl.
        Accepts "5m", "90s", "1h", "500ms" and a bare number meaning seconds.

        Defaults rather than throws. This sits in the path of every request,
        and a typo in config.json should cost you the keep-warm behaviour,
        not her voice. #>
    param([string]$Text, [int]$Default = 300)

    $t = ([string]$Text).Trim().ToLower()
    if (-not $t) { return $Default }
    $m = [regex]::Match($t, '^([0-9]+(?:\.[0-9]+)?)\s*(ms|s|m|h)?$')
    if (-not $m.Success) { return $Default }
    # Invariant culture on the way in as well as the way out: [double]'0.5'
    # is 5 on a machine set to a comma decimal separator.
    $n = 0.0
    if (-not [double]::TryParse($m.Groups[1].Value,
                                [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [ref]$n)) { return $Default }
    switch ($m.Groups[2].Value) {
        'ms' { $n = $n / 1000.0 }
        'm'  { $n = $n * 60.0 }
        'h'  { $n = $n * 3600.0 }
    }
    if ($n -lt 0) { return $Default }
    return [int][math]::Round($n)
}

function Get-BrainEndpoint {
    <#  Every URL that differs between the two, derived from one base address.

        'loaded' is whichever endpoint names the models currently sitting in
        memory: Ollama has /api/ps, LM Studio answers /api/v0/models with a
        state field per model. 'probe' is the liveness check - LM Studio has
        no equivalent of /api/version, so /v1/models does both jobs there. #>
    param([string]$Flavour, [string]$BaseUrl)

    $b = ([string]$BaseUrl).Trim().TrimEnd('/')
    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        if (-not $b) { $b = 'http://127.0.0.1:1234' }
        return @{
            flavour = 'lmstudio'
            base    = $b
            chat    = $b + '/v1/chat/completions'
            probe   = $b + '/v1/models'
            loaded  = $b + '/api/v0/models'
        }
    }
    if (-not $b) { $b = 'http://127.0.0.1:11434' }
    return @{
        flavour = 'ollama'
        base    = $b
        chat    = $b + '/api/chat'
        probe   = $b + '/api/version'
        loaded  = $b + '/api/ps'
    }
}

function Get-BrainSamplingJson {
    <#  The sampling block and the keep-warm instruction: the two places the
        request bodies diverge before the messages start. Returns a fragment
        beginning with a comma, to be pasted in after the model name.

        Ollama nests sampling under "options" and takes keep_alive as a
        duration string. LM Studio is the OpenAI shape - temperature and seed
        at the top level - and spells the same keep-warm idea "ttl", in whole
        seconds, against the JIT-loaded model. repeat_penalty is an Ollama
        option name with no OpenAI equivalent worth guessing at
        (frequency_penalty is a different quantity), so it is not sent.

        $Temp arrives already formatted by Format-BrainTemp, and is a string
        rather than a double on purpose: "$x" on a double renders 0,9 under a
        comma locale and both servers reject the whole body as malformed with
        nothing useful in the error. #>
    param([string]$Flavour, [string]$Temp, [int]$Seed, [string]$KeepAlive)

    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        $ttl = ConvertTo-BrainSeconds $KeepAlive 300
        return (',"temperature":' + $Temp + ',"seed":' + [string]$Seed +
                ',"ttl":' + [string]$ttl)
    }
    return (',"keep_alive":' + ($KeepAlive | ConvertTo-Json) +
            ',"options":{"temperature":' + $Temp + ',"seed":' + [string]$Seed +
            ',"repeat_penalty":1.12}')
}

function ConvertTo-BrainArgsJson {
    <#  Tool-call arguments as a JSON *object*, written as text, whichever way
        they arrived.

        Ollama deserialises arguments for you and hands back an object. The
        OpenAI shape hands back a string containing JSON. Running
        ConvertTo-Json over that string yields a quoted string -
        "{\"path\":\"x\"}" - which goes back on the wire as an argument value
        where an argument object belongs. Ollama shrugs and passes the model
        nonsense; Gemma's chat template stops dead with "tool_calls[].function.
        arguments must be a JSON object (mapping), not a string". So a string
        that parses is handed through exactly as it stands.

        Anything that is not an object becomes an empty one rather than being
        passed on: a bare 5 is valid JSON and is not a set of arguments, and
        ConvertTo-BrainArgs downstream wants something with named keys. #>
    param($Arguments)

    if ($null -eq $Arguments) { return '{}' }
    if ($Arguments -is [string]) {
        $s = $Arguments.Trim()
        if (-not $s) { return '{}' }
        if (-not $s.StartsWith('{')) { return '{}' }
        try { [void]($s | ConvertFrom-Json) } catch { return '{}' }
        return $s
    }
    try {
        $j = $Arguments | ConvertTo-Json -Depth 6 -Compress
        if ([string]::IsNullOrWhiteSpace($j)) { return '{}' }
        if (-not ($j.Trim()).StartsWith('{')) { return '{}' }
        return $j
    } catch { return '{}' }
}

function ConvertFrom-BrainResponse {
    <#  One reply from either backend, flattened to the shape
        Complete-BrainCall consumes: ok, text, toolName, toolArgs, toolId, err.

        The reply sits in a different place in each - Ollama puts it at
        .message, LM Studio at .choices[0].message - and the arguments need
        the unpicking described in ConvertTo-BrainArgsJson.

        Pure, and deliberately outside the runspace that made the request: a
        background runspace cannot see her functions, so the worker returns
        the raw object and the parsing happens back on the UI thread, where it
        can be tested without a server on the other end. #>
    param([string]$Flavour, $Raw)

    $out = @{ ok = $false; text = ''; toolName = ''; toolArgs = ''; toolId = ''; err = '' }
    if (-not $Raw) { $out.err = 'no response'; return $out }

    $msg = $null
    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        try { $msg = @($Raw.choices)[0].message } catch { }
    } else {
        try { $msg = $Raw.message } catch { }
    }
    if (-not $msg) { $out.err = 'no message in the reply'; return $out }

    $out.ok = $true
    try { $out.text = [string]$msg.content } catch { }

    $calls = @()
    try { $calls = @($msg.tool_calls | Where-Object { $_ }) } catch { }
    if ($calls.Count -gt 0 -and $calls[0]) {
        try { $out.toolName = [string]$calls[0].function.name } catch { }
        try { $out.toolId   = [string]$calls[0].id } catch { }
        $out.toolArgs = ConvertTo-BrainArgsJson $calls[0].function.arguments
    }
    return $out
}

function ConvertFrom-ThinkTags {
    <#  Belt to the /no_think brace: strip any reasoning block that arrives
        anyway, so it is neither shown nor spoken.

        Two spellings, because the models disagree. qwen3 emits <think>...
        </think>. Gemma 4 has a thinking channel instead and writes
        <|channel>thought ... <channel|>, which the <think> pattern does not
        touch - left alone it goes through ConvertTo-SpeakableText as ordinary
        prose and she reads her own reasoning out loud, in her own voice, at
        four seconds a sentence. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $out = [System.Text.RegularExpressions.Regex]::Replace(
               $Text, '(?is)<think>.*?</think>', '')
    $out = [System.Text.RegularExpressions.Regex]::Replace(
               $out, '(?is)<\|channel>thought.*?<channel\|>', '')
    # An unclosed block means the model was cut off mid-thought.
    foreach ($marker in @('<think>', '<|channel>thought')) {
        $open = $out.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
        if ($open -ge 0) { $out = $out.Substring(0, $open) }
    }
    return $out.Trim()
}

function Format-BrainToolCall {
    <#  The assistant message recording a tool call, ready for the wire.

        The two backends want the arguments in opposite forms, and there is a
        third form in the middle that is what made this confusing.

        Ollama wants an object: "arguments":{"path":"n.txt"}.

        The OpenAI shape wants a *string* containing JSON:
        "arguments":"{\"path\":\"n.txt\"}". That is the spec, it is what
        LM Studio validates the request against, and sending an object there
        is rejected with a bare 400 and an **empty response body** - no
        message, nothing in her log but the status code.

        The confusing part, and the reason this was written the wrong way
        round first: Gemma's chat template raises "tool_calls[].function.
        arguments must be a JSON object (mapping), not a string". Both things
        are true. LM Studio parses the string off the wire and hands the
        template an object; the template never sees the string form, and the
        API never accepts the object form. The template's error message is
        about a layer below this one and is not advice about what to send.

        The id is what lets LM Studio match a result back to its call: its
        template resolves tool_call_id against the ids on this message and
        falls back to the literal word "unknown" when it cannot. Ollama pays
        no attention to ids and matches by name, so its form is left exactly
        as it was rather than tidied to match - a shape that has been
        answering correctly for months is not worth disturbing to make a diff
        look neater. #>
    param([string]$Flavour, [string]$Name, [string]$ArgsJson, [string]$Id)

    if ([string]::IsNullOrWhiteSpace($ArgsJson)) { $ArgsJson = '{}' }
    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        if (-not $Id) { $Id = 'call_1' }
        # ConvertTo-Json on a string is what does the escaping here: the whole
        # object becomes one JSON string value, quotes and all.
        return ('{"role":"assistant","content":"","tool_calls":[{"id":' + ($Id | ConvertTo-Json) +
                ',"type":"function","function":{"name":' + ($Name | ConvertTo-Json) +
                ',"arguments":' + ($ArgsJson | ConvertTo-Json) + '}}]}')
    }
    return ('{"role":"assistant","content":"","tool_calls":[{"function":{"name":' +
            ($Name | ConvertTo-Json) + ',"arguments":' + $ArgsJson + '}}]}')
}

function Format-BrainToolResult {
    <#  The message carrying a tool's output back.

        Ollama reads the tool's name from "tool_name". The OpenAI shape reads
        it from "name", or resolves "tool_call_id" against the call. Sending
        Ollama's spelling to LM Studio is not an error anyone reports: the
        field is ignored, Gemma's template substitutes the word "unknown", and
        she gets back "response:unknown{...}" for every tool she ever calls -
        losing track of which answer belongs to which question while looking,
        from the outside, like a model that has simply got worse. #>
    param([string]$Flavour, [string]$Name, [string]$Id, [string]$Content)

    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        if (-not $Id) { $Id = 'call_1' }
        return ('{"role":"tool","tool_call_id":' + ($Id | ConvertTo-Json) +
                ',"name":' + ($Name | ConvertTo-Json) +
                ',"content":' + ($Content | ConvertTo-Json) + '}')
    }
    return ('{"role":"tool","tool_name":' + ($Name | ConvertTo-Json) +
            ',"content":' + ($Content | ConvertTo-Json) + '}')
}

function Format-BrainImageMessage {
    <#  A user message carrying one captured frame, in whichever shape the
        backend understands.

        Ollama takes a plain string for content and a sibling "images" array
        of bare base64. The OpenAI shape has no such field: the image travels
        inside content, which stops being a string and becomes an array of
        parts, and the base64 has to be wrapped in a data URI. Send Ollama's
        shape to LM Studio and the request succeeds - the unknown field is
        ignored, the model is asked to describe a picture it was never given,
        and it invents one, fluently, which is the worst of the three
        possible outcomes.

        The base64 is pasted in rather than passed through ConvertTo-Json. It
        is most of a megabyte of [A-Za-z0-9+/=], which contains nothing that
        needs escaping, and ConvertTo-Json on a string that long costs real
        time on the thread that drew her. $Text is escaped properly, because
        that one is hers and can say anything.

        Callers that build the body before the frame exists pass a placeholder
        for $B64 and substitute it later - see Start-EyeVisionCall, which has
        to, because the capture happens on a background runspace that cannot
        see this function. #>
    param([string]$Flavour, [string]$Text, [string]$B64, [string]$Mime = 'image/jpeg')

    if (-not $Mime) { $Mime = 'image/jpeg' }
    # No frame is not an error here: a text-only message is a valid thing to
    # ask for and the caller is better placed to decide whether it wanted one.
    if (-not $B64) { return ('{"role":"user","content":' + ($Text | ConvertTo-Json) + '}') }

    if (([string]$Flavour).ToLower() -eq 'lmstudio') {
        return ('{"role":"user","content":[{"type":"text","text":' + ($Text | ConvertTo-Json) +
                '},{"type":"image_url","image_url":{"url":"data:' + $Mime + ';base64,' + $B64 + '"}}]}')
    }
    return ('{"role":"user","content":' + ($Text | ConvertTo-Json) +
            ',"images":["' + $B64 + '"]}')
}
