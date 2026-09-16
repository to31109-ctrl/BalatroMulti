<#
  Balatro Co-op launcher / installer / updater
  --------------------------------------------
  Double-clicking the "Balatro Co-op" shortcut runs this script, which:
    1. finds Balatro.exe (remembers the location in %LOCALAPPDATA%\BalatroCoop\config.json)
    2. makes sure the Lovely injector (version.dll) is installed next to Balatro.exe
    3. checks GitHub for a newer mod version and installs it into %APPDATA%\Balatro\Mods\BalatroCoop
    4. updates this launcher script itself
    5. starts Balatro

  Run with -Install to also create the desktop shortcut (done by Install-BalatroCoop.bat).
  Run with -NoUpdate to skip the update check.  Run with -NoLaunch to only install/update.
#>
param(
    [switch]$Install,
    [switch]$NoUpdate,
    [switch]$NoLaunch,
    [string]$GameDir,
    [string]$Repo = 'to31109-ctrl/BalatroMulti',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$AppName     = 'Balatro Co-op'
$ModFolder   = 'BalatroCoop'
$StateDir    = Join-Path $env:LOCALAPPDATA 'BalatroCoop'
$ConfigPath  = Join-Path $StateDir 'config.json'
$ModsDir     = Join-Path $env:APPDATA 'Balatro\Mods'
$ModDir      = Join-Path $ModsDir $ModFolder
$RawBase     = "https://raw.githubusercontent.com/$Repo/$Branch"
$ZipUrl      = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$LovelyApi   = 'https://api.github.com/repos/ethangreen-dev/lovely-injector/releases/latest'
$LovelyAsset = 'lovely-x86_64-pc-windows-msvc.zip'
$SelfPath    = $MyInvocation.MyCommand.Path

function Write-Step($msg) { Write-Host "[$AppName] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[$AppName] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[$AppName] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[$AppName] $msg" -ForegroundColor Red }

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# ---------------------------------------------------------------- config
$config = @{}
if (Test-Path $ConfigPath) {
    try {
        $raw = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $config[$p.Name] = $p.Value }
    } catch { $config = @{} }
}
function Save-Config {
    ($config | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding utf8
}

# ---------------------------------------------------------------- find game
function Find-BalatroExe {
    if ($GameDir -and (Test-Path (Join-Path $GameDir 'Balatro.exe'))) { return (Join-Path $GameDir 'Balatro.exe') }
    if ($config.gameExe -and (Test-Path $config.gameExe)) { return $config.gameExe }

    $candidates = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()
    foreach ($reg in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $sp = (Get-ItemProperty -Path $reg -ErrorAction Stop)
            if ($sp.SteamPath) { $steamRoots += $sp.SteamPath }
            if ($sp.InstallPath) { $steamRoots += $sp.InstallPath }
        } catch {}
    }
    $steamRoots += "$env:ProgramFiles(x86)\Steam", "$env:ProgramFiles\Steam"
    foreach ($root in ($steamRoots | Select-Object -Unique)) {
        if (-not $root) { continue }
        $candidates.Add((Join-Path $root 'steamapps\common\Balatro\Balatro.exe'))
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add((Join-Path $lib 'steamapps\common\Balatro\Balatro.exe'))
            }
        }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        $candidates.Add("$($drive.Root)Balatro\Balatro.exe")
        $candidates.Add("$($drive.Root)Balatro\Balatro\Balatro.exe")
        $candidates.Add("$($drive.Root)Games\Balatro\Balatro.exe")
        $candidates.Add("$($drive.Root)SteamLibrary\steamapps\common\Balatro\Balatro.exe")
    }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

    Write-Warn2 'Could not find Balatro.exe automatically.'
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select your Balatro.exe'
        $dlg.Filter = 'Balatro|Balatro.exe'
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    } catch {}
    $typed = Read-Host 'Paste the full path to Balatro.exe'
    if ($typed -and (Test-Path $typed)) { return $typed }
    throw 'Balatro.exe not found.'
}

# ---------------------------------------------------------------- helpers
function Download-File($url, $dest) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'BalatroCoopLauncher' }
        return $true
    } catch {
        Write-Warn2 "Download failed: $url ($($_.Exception.Message))"
        return $false
    }
}

function Get-RemoteText($url) {
    try {
        return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'BalatroCoopLauncher'; 'Cache-Control' = 'no-cache' }).Content.Trim()
    } catch { return $null }
}

function Expand-Zip($zip, $dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

# ---------------------------------------------------------------- lovely
function Ensure-Lovely($gameDirPath) {
    $dll = Join-Path $gameDirPath 'version.dll'
    if (Test-Path $dll) { return }
    Write-Step 'Lovely injector not found, downloading it...'
    try {
        $rel = Invoke-RestMethod -Uri $LovelyApi -Headers @{ 'User-Agent' = 'BalatroCoopLauncher' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -eq $LovelyAsset } | Select-Object -First 1
        if (-not $asset) { throw "asset $LovelyAsset not found in latest release" }
        $zip = Join-Path $StateDir 'lovely.zip'
        if (-not (Download-File $asset.browser_download_url $zip)) { throw 'download failed' }
        $tmp = Join-Path $StateDir 'lovely_tmp'
        Expand-Zip $zip $tmp
        $found = Get-ChildItem -Path $tmp -Recurse -Filter 'version.dll' | Select-Object -First 1
        if (-not $found) { throw 'version.dll missing in archive' }
        Copy-Item $found.FullName $dll -Force
        Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
        Write-Ok "Installed Lovely $($rel.tag_name)"
    } catch {
        Write-Err "Could not install Lovely automatically: $($_.Exception.Message)"
        Write-Err 'Download it manually from https://github.com/ethangreen-dev/lovely-injector/releases and put version.dll next to Balatro.exe.'
    }
}

# ---------------------------------------------------------------- mod update
function Get-InstalledVersion {
    $vf = Join-Path $ModDir 'version.txt'
    if (Test-Path $vf) { return (Get-Content $vf -Raw).Trim() }
    return $null
}

function Update-Mod {
    $installed = Get-InstalledVersion
    $remote = Get-RemoteText "$RawBase/version.txt"
    if (-not $remote) {
        if ($installed) { Write-Warn2 "Could not reach GitHub, keeping installed version $installed."; return }
        throw 'No internet connection and the mod is not installed yet.'
    }
    if ($installed -eq $remote) { Write-Ok "Mod is up to date (v$installed)."; return }
    if ($installed) { Write-Step "Updating mod v$installed -> v$remote ..." } else { Write-Step "Installing mod v$remote ..." }

    $zip = Join-Path $StateDir 'mod.zip'
    if (-not (Download-File $ZipUrl $zip)) { throw 'mod download failed' }
    $tmp = Join-Path $StateDir 'mod_tmp'
    Expand-Zip $zip $tmp
    $srcMod = Get-ChildItem -Path $tmp -Directory -Recurse -Filter 'mod' | Where-Object { Test-Path (Join-Path $_.FullName 'lovely.toml') } | Select-Object -First 1
    if (-not $srcMod) { throw 'downloaded archive has no mod folder' }

    New-Item -ItemType Directory -Force -Path $ModsDir | Out-Null
    if (Test-Path $ModDir) {
        $item = Get-Item $ModDir -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warn2 "$ModDir is a link (developer setup), not replacing it."
            Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
            return
        }
        Remove-Item -Recurse -Force $ModDir
    }
    Copy-Item -Recurse -Force $srcMod.FullName $ModDir
    Set-Content -Path (Join-Path $ModDir 'version.txt') -Value $remote -Encoding ascii

    # self-update the launcher
    $newLauncher = Get-ChildItem -Path $tmp -Recurse -Filter 'BalatroCoop.ps1' | Select-Object -First 1
    if ($newLauncher -and $SelfPath) {
        try { Copy-Item $newLauncher.FullName $SelfPath -Force } catch { Write-Warn2 "Launcher self-update skipped: $($_.Exception.Message)" }
    }
    Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
    Write-Ok "Mod v$remote installed."
}

# ---------------------------------------------------------------- shortcut
function Install-Shortcut($gameExe) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop "$AppName.lnk"
    $target = Join-Path $StateDir 'BalatroCoop.ps1'
    if ($SelfPath -and ($SelfPath -ne $target)) { Copy-Item $SelfPath $target -Force }
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$target`""
    $sc.WorkingDirectory = (Split-Path $gameExe)
    $sc.IconLocation = "$gameExe,0"
    $sc.Description = 'Update and launch Balatro with the Co-op mod'
    $sc.Save()
    Write-Ok "Desktop shortcut created: $lnk"
}

# ---------------------------------------------------------------- firewall
function Ensure-FirewallRule($gameExe) {
    # Lets friends connect when you host. Needs admin once; Windows shows a UAC prompt.
    try {
        $existing = Get-NetFirewallRule -DisplayName 'Balatro Co-op' -ErrorAction SilentlyContinue
        if ($existing) { return }
    } catch {}
    Write-Step 'Adding a Windows Firewall rule so friends can connect to you (UAC prompt)...'
    $cmd = "netsh advfirewall firewall add rule name=`"Balatro Co-op`" dir=in action=allow program=`"$gameExe`" enable=yes profile=any"
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
        Write-Ok 'Firewall rule added.'
    } catch {
        Write-Warn2 "Firewall rule skipped: $($_.Exception.Message). If friends cannot connect, allow Balatro.exe in Windows Firewall."
    }
}

# ---------------------------------------------------------------- broken mods
function Disable-BrokenMods {
    # The BalatroMP stub distributed via BMM deliberately crashes the game on start.
    $mp = Join-Path $ModsDir 'Multiplayer'
    $toml = Join-Path $mp 'lovely.toml'
    if ((Test-Path $toml) -and (Select-String -Path $toml -Pattern 'BMM_MESSAGE' -Quiet)) {
        $dest = Join-Path $env:APPDATA 'Balatro\Multiplayer_disabled_by_coop'
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        Move-Item $mp $dest
        Write-Warn2 'Moved the broken "Multiplayer" stub mod out of the Mods folder (it prevents the game from starting).'
    }
}

# ================================================================ main
try {
    Write-Host ''
    Write-Host "==== $AppName launcher ====" -ForegroundColor Magenta
    $gameExe = Find-BalatroExe
    $gameDirPath = Split-Path $gameExe
    $config.gameExe = $gameExe
    Save-Config
    Write-Step "Game: $gameExe"

    Ensure-Lovely $gameDirPath
    Disable-BrokenMods
    if (-not $NoUpdate) { Update-Mod } else { Write-Warn2 'Update check skipped.' }
    if ($Install) { Install-Shortcut $gameExe; Ensure-FirewallRule $gameExe }

    if (-not $NoLaunch) {
        Write-Step 'Starting Balatro...'
        Start-Process -FilePath $gameExe -WorkingDirectory $gameDirPath
        Start-Sleep -Seconds 2
    } else {
        Write-Ok 'Done.'
        if ($Install) { Read-Host 'Press Enter to close' | Out-Null }
    }
} catch {
    Write-Err "ERROR: $($_.Exception.Message)"
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}
