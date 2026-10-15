#requires -version 5.1
# Registers GLaDOS to launch at login and starts it now.
# No administrator rights required: this only touches your own Startup folder.

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# Everything printed here is also written to install.log, so the result can be
# checked after the window has closed.
$script:InstallLog = Join-Path $Root 'install.log'
try { Set-Content -Path $script:InstallLog -Encoding UTF8 -Value ("GLaDOS install - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) } catch { }

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    try { Add-Content -Path $script:InstallLog -Encoding UTF8 -Value $Text } catch { }
}

Write-Host ''
Write-Host '  APERTURE SCIENCE ENRICHMENT CENTER' -ForegroundColor DarkYellow
Write-Host '  GLaDOS desktop overlay - installation' -ForegroundColor DarkYellow
Write-Host ''

$vbs = Join-Path $Root 'glados.vbs'
$ps1 = Join-Path $Root 'glados.ps1'
$ico = Join-Path $Root 'assets\core.ico'

foreach ($f in @($vbs, $ps1)) {
    if (-not (Test-Path $f)) {
        Say ("  MISSING: " + $f) 'Red'
        Say '  Installation aborted. Keep the whole folder together.' 'Red'
        Start-Sleep -Seconds 20
        exit 1
    }
}

$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'GLaDOS.lnk'

try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments        = '"' + $vbs + '"'
    $lnk.WorkingDirectory = $Root
    $lnk.Description      = 'GLaDOS desktop overlay'
    if (Test-Path $ico) { $lnk.IconLocation = $ico }
    $lnk.Save()

    # Read the shortcut back rather than trusting that Save() worked.
    Start-Sleep -Milliseconds 300
    if (Test-Path $lnkPath) {
        $check = $shell.CreateShortcut($lnkPath)
        Say '  [ok] Startup entry created and verified:' 'Green'
        Say ('       path      ' + $lnkPath)
        Say ('       target    ' + $check.TargetPath)
        Say ('       arguments ' + $check.Arguments)
        Say ('       start in  ' + $check.WorkingDirectory)
    } else {
        Say '  [!!] Save() reported success but the shortcut is not there.' 'Red'
    }
} catch {
    Say ('  [!!] Could not create the startup shortcut: ' + $_.Exception.Message) 'Red'
}

# --- shortcuts you can actually click ---------------------------------------
# The Startup entry above runs her at login and is invisible the rest of the
# time. These are for the times she has been quit and you want her back: one on
# the desktop, one in the Start menu - and the Start menu one is what Windows
# lets you right-click and pin to the taskbar, since pinning cannot be done
# from a script on Windows 10 or 11.
function New-GladosShortcut {
    param([string]$Path, [string]$Label)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($Path)
        $l.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
        $l.Arguments        = '"' + $vbs + '"'
        $l.WorkingDirectory = $Root
        $l.Description      = 'GLaDOS desktop overlay'
        if (Test-Path $ico) { $l.IconLocation = $ico }
        $l.Save()
        Start-Sleep -Milliseconds 200
        if (Test-Path $Path) {
            Say ('  [ok] ' + $Label + ': ' + $Path) 'Green'
            return $true
        }
        Say ('  [!!] ' + $Label + ' reported success but is not there.') 'Red'
        return $false
    } catch {
        Say ('  [!!] Could not create the ' + $Label + ': ' + $_.Exception.Message) 'Red'
        return $false
    }
}

[void](New-GladosShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GLaDOS.lnk') 'Desktop shortcut')

$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'GLaDOS.lnk'
if (New-GladosShortcut $startMenu 'Start menu entry') {
    Say '       (right-click it in the Start menu to pin her to the taskbar)' 'DarkGray'
}

# Retire the previous animation frames once the new set is present. Both
# globs would otherwise load and sort badly (core_0 before core_000).
try {
    $assets = Join-Path $Root 'assets'
    $new = @(Get-ChildItem -Path $assets -Filter 'frame_*.png' -ErrorAction SilentlyContinue)
    $old = @(Get-ChildItem -Path $assets -Filter 'core_*.png' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne 'core.ico' })
    if ($new.Count -gt 0 -and $old.Count -gt 0) {
        $attic = Join-Path $assets 'old_frames'
        New-Item -ItemType Directory -Force -Path $attic | Out-Null
        foreach ($f in $old) { Move-Item $f.FullName (Join-Path $attic $f.Name) -Force -ErrorAction SilentlyContinue }
        Say ('  [ok] Moved ' + $old.Count + ' old frames to assets\old_frames (safe to delete).') 'Green'
    }
} catch {
    Say ('  [--] Could not tidy the old frames: ' + $_.Exception.Message) 'DarkGray'
}

# Large asset sets ship zipped - 178 glow sprites would otherwise be 178
# separate file transfers. Unpack, verify the count, then drop the archive.
try {
    $assets = Join-Path $Root 'assets'
    foreach ($pack in @(Get-ChildItem -Path $Root -Filter '*.assetpack.zip' -ErrorAction SilentlyContinue)) {
        Expand-Archive -LiteralPath $pack.FullName -DestinationPath $assets -Force
        $warm = @(Get-ChildItem -Path $assets -Filter 'glowwarm_*.png' -ErrorAction SilentlyContinue).Count
        $cool = @(Get-ChildItem -Path $assets -Filter 'glowcool_*.png' -ErrorAction SilentlyContinue).Count
        if ($warm -gt 0 -and $warm -eq $cool) {
            Say ('  [ok] Unpacked ' + $pack.Name + ' - ' + $warm + ' glow sprites per colour.') 'Green'
            Remove-Item $pack.FullName -Force -ErrorAction SilentlyContinue
        } else {
            Say ('  [!!] ' + $pack.Name + ' unpacked oddly: warm=' + $warm + ' cool=' + $cool) 'Red'
            Say '       The glow will not load. The archive was left in place.' 'Red'
        }
    }
} catch {
    Say ('  [!!] Could not unpack the asset archive: ' + $_.Exception.Message) 'Red'
}

# The first glow used one silhouette for every frame and did not track her.
try {
    $assets = Join-Path $Root 'assets'
    $stale = @(Get-ChildItem -Path $assets -Filter 'glow_*.png' -ErrorAction SilentlyContinue)
    if ($stale.Count -gt 0 -and (Test-Path (Join-Path $assets 'glowwarm_000.png'))) {
        $attic = Join-Path $assets 'old_frames'
        New-Item -ItemType Directory -Force -Path $attic | Out-Null
        foreach ($f in $stale) { Move-Item $f.FullName (Join-Path $attic $f.Name) -Force -ErrorAction SilentlyContinue }
        Say ('  [ok] Retired ' + $stale.Count + ' first-generation glow sprites.') 'Green'
    }
} catch { }

# Unblock files that Windows may have marked as downloaded from the internet.
try {
    Get-ChildItem -Path $Root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Say '  [ok] Files unblocked.' 'Green'
} catch { }

Write-Host ''
Say '  Starting GLaDOS...' 'DarkYellow'
try {
    $already = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -and $_.CommandLine -like '*glados.ps1*' })
    if ($already.Count -gt 0) {
        Say ('  [ok] Already running (pid ' + ($already[0].ProcessId) + '). Leaving her alone.') 'Green'
    } else {
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
                      -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $Root
        Start-Sleep -Seconds 3
        $now = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -and $_.CommandLine -like '*glados.ps1*' })
        if ($now.Count -gt 0) {
            Say ('  [ok] She is awake (pid ' + ($now[0].ProcessId) + ').') 'Green'
        } else {
            Say '  [!!] Launched, but no GLaDOS process is running. Check glados.log.' 'Red'
        }
    }
} catch {
    Say ('  [!!] Could not start: ' + $_.Exception.Message) 'Red'
}

Write-Host ''
Write-Host '  Controls:' -ForegroundColor DarkYellow
Write-Host '    left-click and drag  ...  move her (position is remembered)'
Write-Host '    left-click           ...  open / close the chat window'
Write-Host '    right-click          ...  menu (chat, reset position, config, quit)'
Write-Host '    tray icon            ...  same menu, always reachable'
Write-Host ''
Write-Host '  In the chat window, type /help for commands.'
Write-Host '  To remove her from startup, run Uninstall.cmd.'
Write-Host ''
Write-Host ('  A copy of this result was written to ' + $script:InstallLog) -ForegroundColor DarkGray
Write-Host ''
for ($i = 20; $i -gt 0; $i--) {
    Write-Host ("`r  Closing in " + $i + " seconds...   ") -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
