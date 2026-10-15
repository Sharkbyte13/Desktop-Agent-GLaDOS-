#requires -version 5.1
# ===========================================================================
#  The eye's cadence and suppression rules - regression test
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_vision_cadence.ps1
#
#  uilogic.ps1 has no WinForms in it, which is what makes this possible: the
#  question "should she remark on the screen right now" can be answered without
#  a graphics card, a game, or a screenshot.
#
#  What it guards: an ambient remark that fires too often, or that talks over
#  the user, or that describes a black exclusive-fullscreen frame, is worse
#  than one that never comes. Each rule below is one of those failures.
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

# A yes with everything favourable, that each case then spoils one way at a time.
function Decide {
    param($over)
    $p = @{
        Enabled = $true; Now = 1000; DueAt = 500; Speaking = $false
        LastExchangeAt = 0; QuietSeconds = 30; OnlyInGame = $true; GameActive = $true
        Blank = $false; Sig = 'aaaa'; LastSig = 'bbbb'; Count = 0; Cap = 40
    }
    if ($over) { foreach ($k in $over.Keys) { $p[$k] = $over[$k] } }
    return Get-VisionCommentDecision @p
}

Write-Host 'the happy path'
Assert-True  'everything favourable is a go' (Decide @{}).go
Assert-Equal 'and it says so' 'ok' (Decide @{}).why

Write-Host 'the reasons she stays quiet'
Assert-True  'off means off'            (-not (Decide @{ Enabled = $false }).go)
Assert-Equal 'off is named'      'off'  (Decide @{ Enabled = $false }).why
Assert-True  'not due yet'              (-not (Decide @{ Now = 400; DueAt = 500 }).go)
Assert-True  'speaking'                 (-not (Decide @{ Speaking = $true }).go)
Assert-True  'just spoke with the user' (-not (Decide @{ LastExchangeAt = 990; Now = 1000; QuietSeconds = 30 }).go)
Assert-True  'no game and only-in-game' (-not (Decide @{ GameActive = $false; OnlyInGame = $true }).go)
Assert-True  'a blank (fullscreen) frame' (-not (Decide @{ Blank = $true }).go)
Assert-True  'an unchanged screen'      (-not (Decide @{ Sig = 'aaaa'; LastSig = 'aaaa' }).go)
Assert-True  'the session cap'          (-not (Decide @{ Count = 40; Cap = 40 }).go)

Write-Host 'the edges of each rule'
Assert-True  'exactly due is a go'          (Decide @{ Now = 500; DueAt = 500 }).go
Assert-True  'inside the quiet window is quiet'  (-not (Decide @{ LastExchangeAt = 990; Now = 1000; QuietSeconds = 30 }).go)
Assert-True  'exactly at the quiet edge is free' (Decide @{ LastExchangeAt = 970; Now = 1000; QuietSeconds = 30 }).go
Assert-True  'one second inside is still quiet'  (-not (Decide @{ LastExchangeAt = 971; Now = 1000; QuietSeconds = 30 }).go)
Assert-True  'no prior exchange never suppresses' (Decide @{ LastExchangeAt = 0; Now = 1000; DueAt = 0 }).go
Assert-True  'only-in-game off lets her talk on the desktop' (Decide @{ GameActive = $false; OnlyInGame = $false }).go
Assert-True  'a cap of 0 is no cap'         (Decide @{ Count = 999; Cap = 0 }).go
Assert-True  'one below the cap is a go'    (Decide @{ Count = 39; Cap = 40 }).go
Assert-True  'an empty sig is never "unchanged"' (Decide @{ Sig = ''; LastSig = '' }).go

Write-Host 'priority: a "no" is reported by its cheapest reason'
Assert-Equal 'off outranks everything' 'off' (Decide @{ Enabled = $false; Now = 0; DueAt = 999 }).why
Assert-Equal 'not-due outranks speaking' 'not due' (Decide @{ Now = 10; DueAt = 999; Speaking = $true }).why
Assert-Equal 'cap outranks speaking' 'session cap reached' (Decide @{ Count = 40; Cap = 40; Speaking = $true }).why

Write-Host 'the next-delay draw'
$outOfRange = 0
for ($i = 0; $i -lt 200; $i++) {
    $d = Get-NextVisionDelay 150 420
    if ($d -lt 150 -or $d -gt 420) { $outOfRange++ }
}
Assert-Equal '200 draws all within [150,420]' 0 $outOfRange
Assert-Equal 'a degenerate window returns the floor' 150 (Get-NextVisionDelay 150 150)
Assert-True  'a swapped pair does not throw or invert' ((Get-NextVisionDelay 400 100) -ge 400)
Assert-True  'a silly-low floor is clamped up'          ((Get-NextVisionDelay 1 1) -ge 15)

Write-Host 'the caption usability guard (stage one output before it reaches stage two)'
Assert-True  'a real caption passes' `
    (Test-EyeDescriptionUsable 'The image shows a computer screen with a game open, a character standing in a forest.')
Assert-True  'a short real caption passes' (Test-EyeDescriptionUsable 'A player fights a boss in a dark arena.')
Assert-True  'null is rejected'           (-not (Test-EyeDescriptionUsable $null))
Assert-True  'empty is rejected'          (-not (Test-EyeDescriptionUsable ''))
Assert-True  'whitespace is rejected'     (-not (Test-EyeDescriptionUsable '     '))
Assert-True  'too short is rejected'      (-not (Test-EyeDescriptionUsable 'a game'))
Assert-True  'one long token is rejected' (-not (Test-EyeDescriptionUsable 'aaaaaaaaaaaaaaaaaaaaaaaa'))
Assert-True  'the urn junk is rejected'   (-not (Test-EyeDescriptionUsable 'urn:SystemVerilog.org:portions:0.0,0.0,0.99,0.99'))
Assert-True  'the hex/scheme junk is rejected' (-not (Test-EyeDescriptionUsable 'urn:system.fs.se:8:47:46:8:52:46:5:67:7:79:89:75:97'))
Assert-True  'a scheme-prefixed token is rejected' (-not (Test-EyeDescriptionUsable 'system:foo bar baz qux'))
Assert-True  'mostly-digits is rejected'  (-not (Test-EyeDescriptionUsable '12 34 56 78 90 12 34 56 78 90 12 34'))

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'all good.' }
else { Write-Host ($script:Failed.ToString() + ' failed.') }
exit $script:Failed
