#requires -version 5.1
# ===========================================================================
#  How a reply is broken into caption lines - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_caption_lines.ps1
#
#  uilogic.ps1 has no WinForms in it, so the breaks can be checked without
#  putting a window on the screen. The pixel measurement that sizes the box
#  cannot be tested here, only the arithmetic either side of it.
#
#  What it is guarding: the box used to fill each line to the character limit
#  and start a new one at the first word that did not fit, so
#  "You're welcome to enjoy your brief moment of... urgency." came out as
#  three lines, the last two of which were "of..." and "urgency." Lines are
#  now aimed at an even share of the sentence, and short sentences share a
#  line rather than each taking one.
# ===========================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
function Write-Log { param([string]$Message) }

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
. (Join-Path $root 'uilogic.ps1')

$script:Failed = 0

function Assert-True {
    param([string]$What, $Value)
    if ($Value) { Write-Host ('  ok   ' + $What) }
    else { Write-Host ('  FAIL ' + $What); $script:Failed++ }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)
    if ([string]$Expected -eq [string]$Actual) { Write-Host ('  ok   ' + $What) }
    else {
        Write-Host ('  FAIL ' + $What)
        Write-Host ('       expected: ' + $Expected)
        Write-Host ('       got     : ' + $Actual)
        $script:Failed++
    }
}

$max = 72

Write-Host 'the line that started this'
$lines = @(Split-CaptionLines "You're welcome to enjoy your brief moment of... urgency." $max)
Assert-Equal 'one line, not three' 1 $lines.Count
Assert-Equal 'all of it' "You're welcome to enjoy your brief moment of... urgency." $lines[0]

Write-Host 'short sentences share a line'
$lines = @(Split-CaptionLines 'Yes. No. Obviously. Try again.' $max)
Assert-Equal 'packed into one' 1 $lines.Count

Write-Host 'a sentence too long for one line is split evenly'
$sentence = 'Congratulations on completing a task a well-trained bird could have managed with a suitably shaped beak and sufficient motivation.'
$lines = @(Split-CaptionLines $sentence $max)
Assert-Equal 'two lines, no scrap' 2 $lines.Count
Assert-True  'neither is a fragment' (([string]$lines[0]).Length -gt 40 -and ([string]$lines[1]).Length -gt 40)

Write-Host 'nothing overruns the limit'
$long = 'One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty.'
foreach ($text in @($long, $sentence, 'A. B. C. D. E. F. G. H. I. J. K. L. M. N. O. P.')) {
    foreach ($width in @(24, 46, 72)) {
        $out = @(Split-CaptionLines $text $width)
        $over = 0
        for ($i = 0; $i -lt $out.Count; $i++) {
            $l = [string]$out[$i]
            # The last line is allowed the slack the orphan glue takes, and a
            # single word longer than the limit has nowhere to break at all.
            $limit = $width
            if ($i -eq ($out.Count - 1)) { $limit = $width + 8 }
            if ($l.Length -gt $limit -and $l -match '\s') { $over++ }
        }
        Assert-Equal ('width ' + $width + ' holds') 0 $over
    }
}

Write-Host 'nothing to say'
Assert-Equal 'empty text is no lines' 0 (@(Split-CaptionLines '' $max)).Count
Assert-Equal 'whitespace is no lines'  0 (@(Split-CaptionLines "  `t " $max)).Count
Assert-Equal 'a word is one line'      1 (@(Split-CaptionLines 'Hmm?' $max)).Count

Write-Host 'how many rows the box needs'
Assert-Equal 'one line, one row'    1 (Get-CaptionRows 1)
Assert-Equal 'two lines, two rows'  2 (Get-CaptionRows 2)
Assert-Equal 'more never exceeds 3' 3 (Get-CaptionRows 9)

Write-Host 'the box follows the lines it is showing'
$narrow = Get-CaptionBoxSize 100 3 520
$wide   = Get-CaptionBoxSize 400 3 520
Assert-True  'a short line gets a small box' ($narrow.width -lt $wide.width)
Assert-True  'never below the floor'         ((Get-CaptionBoxSize 0 1 520).width -ge 180)
Assert-True  'never past the ceiling'        ((Get-CaptionBoxSize 4000 3 520).width -le 520)
Assert-Equal 'height is rows, not width'     $narrow.height $wide.height

Write-Host 'and changes width without flicker'
Assert-Equal 'growing happens at once' 470 (Get-CaptionWidthStep 200 470)
$w = 470
$steps = 0
while ($w -ne 260 -and $steps -lt 40) { $w = Get-CaptionWidthStep $w 260; $steps++ }
Assert-Equal 'shrinking arrives'        260 $w
Assert-True  'shrinking is eased, not a snap' ($steps -gt 3 -and $steps -lt 30)
Assert-Equal 'already there is a no-op' 300 (Get-CaptionWidthStep 300 300)

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
