#requires -version 5.1
# ===========================================================================
#  How she talks about a timer - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_timer_wording.ps1
#
#  uilogic.ps1 has no WinForms in it, which is what makes this possible: the
#  wording can be checked without putting a window on the screen.
#
#  What it is guarding: set_timer's label defaults to the word "timer", so an
#  unnamed timer announced itself as "Your timer has expired: timer." She now
#  only names one when someone actually chose a name.
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

Write-Host 'a label that says nothing is treated as no label'
foreach ($l in @('timer', 'Timer', ' timer ', 'timer.', 'a timer', 'the timer',
                 'countdown', 'alarm', 'reminder', 'none', 'n/a', '', '   ')) {
    Assert-True ('"' + $l + '" is generic') (Test-GenericTimerLabel $l)
}

Write-Host 'a label that says something is kept'
foreach ($l in @('pasta', 'the pasta', 'tea', 'call mum', 'laundry',
                 'timer for the oven', 'stand up')) {
    Assert-True ('"' + $l + '" is a real label') (-not (Test-GenericTimerLabel $l))
}

Write-Host 'the expiry line'
Assert-Equal 'unnamed timer says nothing about what it was' `
    'Your timer has expired. Time, unlike you, is reliable.' `
    (Get-TimerExpiryLine 'timer' 'timer')
Assert-Equal 'an empty label is the same' `
    'Your timer has expired. Time, unlike you, is reliable.' `
    (Get-TimerExpiryLine '' 'timer')
Assert-Equal 'a named timer is named' `
    'Your timer has expired: the pasta. Time, unlike you, is reliable.' `
    (Get-TimerExpiryLine 'the pasta' 'timer')
Assert-Equal 'a trailing stop is not doubled' `
    'Your timer has expired: the pasta. Time, unlike you, is reliable.' `
    (Get-TimerExpiryLine 'the pasta.' 'timer')

Write-Host 'the reminder line'
Assert-Equal 'a named reminder is quoted back' `
    'Reminder: call mum. You asked me to say that. I have said it.' `
    (Get-TimerExpiryLine 'call mum' 'reminder')
Assert-True 'an unnamed reminder does not read out the word "reminder" as its subject' `
    ((Get-TimerExpiryLine 'reminder' 'reminder') -notmatch 'Reminder: reminder')

Write-Host 'the cancelled lines'
$lines = @(Get-TimerDeletedLines 'timer' ' Bold.')
Assert-Equal 'three of them, as before' 3 $lines.Count
Assert-True  'none of them says "deleted: timer"' `
    (-not (@($lines | Where-Object { $_ -match 'timer' -and $_ -match ':' }).Count))
Assert-True  'the tail is still on the end' ($lines[0] -match 'Bold\.$')
$lines = @(Get-TimerDeletedLines 'the pasta' '')
Assert-True  'a named one is still named' ($lines[0] -match 'the pasta')

Write-Host 'the startup sweep'
Assert-Equal 'one unnamed timer' `
    '1 timer came due while I was not running. I have let them go.' `
    (Get-StaleTimerLine @('timer'))
Assert-Equal 'two unnamed timers' `
    '2 timers came due while I was not running. I have let them go.' `
    (Get-StaleTimerLine @('timer', 'timer'))
Assert-Equal 'two, one of them named' `
    '2 timers came due while I was not running (the pasta). I have let them go.' `
    (Get-StaleTimerLine @('timer', 'the pasta'))

Write-Host 'the button caption'
Assert-Equal 'one hidden'   'view timer'    (Get-ShowTimerLabel 1)
Assert-Equal 'three hidden' 'view 3 timers' (Get-ShowTimerLabel 3)
Assert-Equal 'nonsense is still a caption' 'view timer' (Get-ShowTimerLabel 0)

Write-Host 'stale transcripts from the voice inbox'
Assert-True  'something said just now is live'      (-not (Test-TranscriptStale 0.4 120))
Assert-True  'a slow answer is still live at 90s'   (-not (Test-TranscriptStale 90 120))
Assert-True  'exactly at the limit is still live'   (-not (Test-TranscriptStale 120 120))
Assert-True  'a second past the limit is stale'     (Test-TranscriptStale 121 120)
Assert-True  'an hour old is stale'                 (Test-TranscriptStale 3600 120)
Assert-True  'clock skew does not drop live speech' (-not (Test-TranscriptStale -5 120))
Assert-True  'a limit of 0 turns the check off'     (-not (Test-TranscriptStale 3600 0))

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
