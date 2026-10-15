#requires -version 5.1
# ===========================================================================
#  When the microphone stays open after she answers - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_followup.ps1
#
#  What it is guarding: the follow-up window used to open on any question mark
#  anywhere in a reply. She is written to be sardonic and lands one in most of
#  them, so "Timer #1 set, in 25 seconds. Enjoy your brief moment of focus...
#  or is that another distraction?" left the microphone open for thirty
#  seconds after a job that was already done - which looks, from the outside,
#  exactly like she is stuck waiting for something.
#
#  The rule now: she is asking only when she needs an answer to go on.
# ===========================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
function Write-Log { param([string]$Message) }

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
. (Join-Path $root 'uilogic.ps1')

$script:Failed = 0

function Assert-Open {
    param([string]$Text)
    if (Test-WantsFollowUp $Text 'question') { Write-Host ('  ok   opens: ' + $Text) }
    else { Write-Host ('  FAIL should open: ' + $Text); $script:Failed++ }
}

function Assert-Shut {
    param([string]$Text)
    if (Test-WantsFollowUp $Text 'question') { Write-Host ('  FAIL should not open: ' + $Text); $script:Failed++ }
    else { Write-Host ('  ok   stays shut: ' + $Text) }
}

Write-Host 'sarcasm is not a question'
Assert-Shut 'Timer #1 set, in 25 seconds. Enjoy your brief moment of focus... or is that another distraction?'
Assert-Shut 'Done. Was that so hard?'
Assert-Shut 'The file is saved. Impressive, isn''t it?'
Assert-Shut 'Volume at 40 percent. Who knew you had neighbours?'
Assert-Shut 'Note taken. Do you want to know how many you have never read?'
Assert-Shut 'I have opened Notepad. How original.'
Assert-Shut 'Three timers are running. Ambitious, aren''t you?'

Write-Host 'and neither is her quoting you'
Assert-Shut 'You said "should I delete it?" and then went quiet. I did nothing.'

Write-Host 'a real request holds the microphone open'
Assert-Open 'There are two files called notes.txt. Which one did you mean?'
Assert-Open 'That would overwrite the original. Shall I continue?'
Assert-Open 'Are you sure? The folder has 412 files in it.'
Assert-Open 'I can mute the microphone or close the window. Which one?'
Assert-Open 'Tell me which drive you meant and I will look again.'
Assert-Open 'How long do you want the timer to run?'
Assert-Open 'Would you like me to read it back to you?'
Assert-Open 'I found nothing by that name. Did you mean the desktop?'
Assert-Open 'Say the word and it goes in the recycle bin.'

Write-Host 'the modes still override everything'
Assert-Shut ''
$mute = 'Which one did you mean?'
if (Test-WantsFollowUp $mute 'off') { Write-Host '  FAIL off still opened'; $script:Failed++ }
else { Write-Host '  ok   off never opens' }
if (Test-WantsFollowUp 'Done.' 'always') { Write-Host '  ok   always opens on anything' }
else { Write-Host '  FAIL always did not open'; $script:Failed++ }

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
