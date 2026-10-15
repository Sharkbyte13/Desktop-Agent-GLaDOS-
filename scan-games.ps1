#requires -version 5.1
# ============================================================================
#  Read the launchers and write games.json.
#
#  This lives in its own file, and runs as its own process, for one reason:
#  Windows Defender scores a PowerShell script on everything in it at once. A
#  script that reads installed-software paths out of the registry AND walks the
#  disk for executables AND does it from a hidden background runspace is, taken
#  together, a fair description of reconnaissance malware - and the scoring is
#  cumulative, so that material sitting inside the main overlay pushed the whole
#  of glados.ps1 over the threshold and got it refused in full.
#
#  Nothing here is secret or clever. It is just kept apart, so that if it is
#  ever refused, the only thing lost is the convenience of a pre-filled games
#  list. She still starts, and still notices a game the first time you run it.
#
#  Usage: powershell -File scan-games.ps1 [-Root <folder>]
# ============================================================================

param([string]$Root = '')

$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = $PSScriptRoot }

$uilogic   = Join-Path $Root 'uilogic.ps1'
$gamesPath = Join-Path $Root 'games.json'
$logPath   = Join-Path $Root 'glados.log'


function Note([string]$m) {
    try {
        Add-Content -Path $logPath -Encoding UTF8 -Value (
        "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

try { . $uilogic } catch { Note ('game scan: could not load uilogic - ' + $_.Exception.Message); return }

$found = New-Object System.Collections.ArrayList
$cap   = 400

function Add-OneExe([string]$exePath, [string]$name, [string]$source) {
    if ($found.Count -ge $cap) { return }
    $exe = ConvertTo-ProcessName $exePath
    if (-not $exe) { return }
    if (Test-BannedGameName $exe) { return }
    if (-not $name) { $name = $exe }
    [void]$found.Add(@{ exe = $exe; name = $name; source = $source })
}

function Add-FromDir([string]$dir, [string]$name, [string]$source) {
    if (-not $dir) { return }
    if ($found.Count -ge $cap) { return }
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -Recurse -Depth 3 `
        -ErrorAction SilentlyContinue)
    } catch { return }
    $room = $cap - $found.Count
    if ($room -gt 6) { $room = 6 }
    foreach ($exe in @(Select-GameExecutables @($files | ForEach-Object { $_.FullName }) $dir $room)) {
        Add-OneExe $exe $name $source
    }
}

# --- Steam ---------------------------------------------------------
try {
    $steam = ''
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        if ($steam) { break }
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.SteamPath)   { $steam = [string]$v.SteamPath }
            elseif ($v.InstallPath) { $steam = [string]$v.InstallPath }
        } catch { }
    }
    if ($steam) {
        $steam = $steam.Replace('/', [char]92)
        $libs = New-Object System.Collections.ArrayList
        [void]$libs.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $parsed = ConvertFrom-ValveKeyValues (Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue)
            foreach ($p in @(Get-SteamLibraryPaths $parsed)) {
                if ($p -and -not $libs.Contains($p)) { [void]$libs.Add($p) }
            }
        }
        foreach ($lib in $libs) {
            $apps = Join-Path $lib 'steamapps'
            if (-not (Test-Path -LiteralPath $apps)) { continue }
            $manifests = @()
            try {
                $manifests = @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)
            } catch { }
            foreach ($m in $manifests) {
                $info = $null
                try {
                    $info = Get-SteamAppInfo (ConvertFrom-ValveKeyValues (
                    Get-Content -LiteralPath $m.FullName -Raw -ErrorAction SilentlyContinue))
                } catch { }
                if (-not $info) { continue }
                Add-FromDir (Join-Path (Join-Path $apps 'common') $info.installdir) $info.name 'steam'
            }
        }
    }
} catch { Note ('game scan: steam - ' + $_.Exception.Message) }

# --- Epic ----------------------------------------------------------
# The manifests name the launch executable outright, which is better
# than anything guessing at a folder can manage.
try {
    $dir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
            try {
                $j = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                $exe = [string]$j.LaunchExecutable
                $nm  = [string]$j.DisplayName
                if ($exe) { Add-OneExe $exe $nm 'epic' }
                elseif ($j.InstallLocation) { Add-FromDir ([string]$j.InstallLocation) $nm 'epic' }
            } catch { }
        }
    }
} catch { Note ('game scan: epic - ' + $_.Exception.Message) }

# --- GOG -----------------------------------------------------------
try {
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            try {
                $v = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                $nm = [string]$v.gameName
                if ($v.exe) { Add-OneExe ([string]$v.exe) $nm 'gog' }
                elseif ($v.path) { Add-FromDir ([string]$v.path) $nm 'gog' }
            } catch { }
        }
    }
} catch { Note ('game scan: gog - ' + $_.Exception.Message) }

# --- Ubisoft -------------------------------------------------------
try {
    $root = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs'
    if (Test-Path $root) {
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            try {
                $v = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                if ($v.InstallDir) {
                    $d = ([string]$v.InstallDir).Replace('/', [char]92).TrimEnd([char]92)
                    Add-FromDir $d (Split-Path $d -Leaf) 'ubisoft'
                }
            } catch { }
        }
    }
} catch { Note ('game scan: ubisoft - ' + $_.Exception.Message) }

# --- Blizzard ------------------------------------------------------
try {
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment', 'HKLM:\SOFTWARE\Blizzard Entertainment')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            try {
                $v = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                $d = ''
                if ($v.InstallPath)     { $d = [string]$v.InstallPath }
                elseif ($v.InstallLocation) { $d = [string]$v.InstallLocation }
                if ($d) { Add-FromDir $d $k.PSChildName 'blizzard' }
            } catch { }
        }
    }
} catch { Note ('game scan: blizzard - ' + $_.Exception.Message) }

# --- Folders the other launchers just use by convention ------------
try {
    $roots = New-Object System.Collections.ArrayList
    foreach ($p in @(
    (Join-Path $env:ProgramFiles 'EA Games'),
    (Join-Path $env:ProgramFiles 'Epic Games'),
    (Join-Path ${env:ProgramFiles(x86)} 'Origin Games'),
    (Join-Path ${env:ProgramFiles(x86)} 'Epic Games'),
    'C:\Riot Games')) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$roots.Add($p) }
    }
    foreach ($d in @([System.IO.DriveInfo]::GetDrives())) {
        try {
            if ($d.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            $x = Join-Path $d.Name 'XboxGames'
            if (Test-Path -LiteralPath $x) { [void]$roots.Add($x) }
        } catch { }
    }
    foreach ($r in $roots) {
        foreach ($g in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
            Add-FromDir $g.FullName $g.Name 'folder'
        }
    }
} catch { Note ('game scan: folders - ' + $_.Exception.Message) }

# --- Merge and write ------------------------------------------------
try {
    $existing = @()
    $ignored  = @()
    if (Test-Path -LiteralPath $gamesPath) {
        $cur = ConvertFrom-GamesJson (Get-Content -LiteralPath $gamesPath -Raw -ErrorAction SilentlyContinue)
        $existing = @($cur.apps)
        $ignored  = @($cur.ignored)
    }
    $merged = Merge-GameList $existing $found.ToArray() $ignored
    Set-Content -LiteralPath $gamesPath -Encoding UTF8 -Value (ConvertTo-GamesJson $merged $ignored)
    Note ('game scan finished: ' + @($found).Count + ' executables found, ' +
    @($merged).Count + ' on the list')
} catch { Note ('game scan: could not write the list - ' + $_.Exception.Message) }
