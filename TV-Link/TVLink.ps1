# TV Link: lets TV Home show your PC's stats, use your Wallpaper Engine wallpapers and wake the PC.
# Runs quietly in the background on port 8787 (home network only). Started by "Install TV Link.bat".
$ErrorActionPreference = 'Continue'
$Port = 8787
# Also in /info and /stats below. A newer TV Link takes over from an older one still running.
$LinkVersion = 12
$logFile = Join-Path $env:LOCALAPPDATA 'TVLink\tvlink.log'
try { Start-Transcript -Path $logFile -Force | Out-Null } catch { }

# ---------- one-off info ----------
function Get-PcInfo {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    if ($cpu) { $cpu = ($cpu -replace '\s+', ' ' -replace '\(R\)|\(TM\)', '' -replace ' \d+-Core Processor', '' -replace ' CPU', '').Trim() }
    $gpu = ''
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($smi) { $gpu = (& $smi.Source --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1) }
    if (-not $gpu) { $gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } | Select-Object -First 1).Name }
    if ($gpu) { $gpu = ($gpu -replace 'NVIDIA GeForce ', '' -replace 'NVIDIA ', '' -replace 'AMD Radeon ', 'Radeon ').Trim() }
    $mac = ''
    try {
        $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
        if ($cfg) { $mac = ($cfg.NetAdapter.MacAddress -replace '-', ':') }
    } catch { }
    [pscustomobject]@{ cpu = $cpu; gpu = $gpu; mac = $mac; name = $env:COMPUTERNAME; smi = $(if ($smi) { $smi.Source } else { '' }) }
}

# ---------- Wallpaper Engine ----------
function Get-WallpaperEngine {
    $libs = @()
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath -replace '/', '\'
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
        }
    } catch { }
    $libs = $libs | Select-Object -Unique
    $exe = ''
    $dirs = @()
    foreach ($l in $libs) {
        $we = Join-Path $l 'steamapps\common\wallpaper_engine'
        if (-not $exe -and (Test-Path (Join-Path $we 'wallpaper64.exe'))) { $exe = Join-Path $we 'wallpaper64.exe' }
        $dirs += @(Join-Path $l 'steamapps\workshop\content\431960')
        $dirs += @(Join-Path $we 'projects\myprojects')
        $dirs += @(Join-Path $we 'projects\defaultprojects')
    }
    $items = @{}
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($p in Get-ChildItem $d -Directory -ErrorAction SilentlyContinue) {
            $pj = Join-Path $p.FullName 'project.json'
            if (-not (Test-Path $pj)) { continue }
            try { $j = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $type = ("" + $j.type).ToLower()
            if (-not $type) { $type = 'scene' }
            $id = $p.Name
            $items[$id] = [pscustomobject]@{
                id = $id; title = ("" + $j.title).Trim(); type = $type
                dir = $p.FullName; file = ("" + $j.file); preview = ("" + $j.preview)
            }
        }
    }
    [pscustomobject]@{ exe = $exe; items = $items }
}

# ---------- Windows wallpapers (for PCs with or without Wallpaper Engine) ----------
# Windows' own wallpapers, the last few desktop wallpapers used, and Windows Spotlight pictures.
function Get-PcWalls {
    $items = [ordered]@{}
    $md5 = [Security.Cryptography.MD5]::Create()
    function Add-Wall([string]$path, [string]$kind, [string]$title) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $id = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLower()))) -replace '-', '').Substring(0, 12).ToLower()
        if (-not $items.Contains($id)) { $items[$id] = [pscustomobject]@{ id = $id; title = $title; kind = $kind; path = $path } }
    }
    # Your own TV wallpapers: any picture or video put in Pictures\TV Wallpapers (or Downloads\TV Wallpapers)
    foreach ($d in @((Join-Path ([Environment]::GetFolderPath('MyPictures')) 'TV Wallpapers'), (Join-Path $env:USERPROFILE 'Downloads\TV Wallpapers'))) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png|webp|mp4|webm)$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 60)) {
            Add-Wall $f.FullName 'mine' ([IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '[_-]+', ' ')
        }
    }
    # Recently used desktop wallpapers (Settings > Personalisation keeps five)
    try {
        $h = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -ErrorAction Stop
        for ($i = 0; $i -lt 5; $i++) {
            $p = $h.("BackgroundHistoryPath$i")
            if ($p) { Add-Wall $p 'recent' ([IO.Path]::GetFileNameWithoutExtension($p)) }
        }
    } catch { }
    # Windows' own wallpapers
    $names = @{ 'Windows' = 'Bloom'; 'ThemeA' = 'Glow'; 'ThemeB' = 'Captured Motion'; 'ThemeC' = 'Sunrise'; 'ThemeD' = 'Flow'; 'Spotlight' = 'Spotlight' }
    $web = Join-Path $env:WINDIR 'Web\Wallpaper'
    foreach ($d in @(Get-ChildItem -LiteralPath $web -Directory -ErrorAction SilentlyContinue)) {
        $n = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' } | Sort-Object Name)) {
            $n++
            $base = if ($names.ContainsKey($d.Name)) { $names[$d.Name] } else { $d.Name }
            Add-Wall $f.FullName 'windows' $(if ($n -gt 1) { "$base $n" } else { $base })
        }
    }
    # Afterglow's backgrounds (pictures and videos made for the TV)
    foreach ($d in @((Join-Path $env:LOCALAPPDATA 'Afterglow\tv-backgrounds'), (Join-Path $env:LOCALAPPDATA 'Afterglow\renderer'))) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png|webp|mp4|webm)$' -and $_.Length -gt 30KB } | Sort-Object LastWriteTime -Descending | Select-Object -First 40)) {
            Add-Wall $f.FullName 'afterglow' ([IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '[_-]+', ' ')
        }
    }
    # Windows Spotlight pictures (landscape, at least 1920 wide)
    $spot = @()
    $spot += @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\LocalState\Assets') -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 150KB })
    $spot += @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\LocalCache\Microsoft\IrisService') -Recurse -File -Include *.jpg -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 150KB })
    if ($spot.Count) {
        try { Add-Type -AssemblyName System.Drawing } catch { }
        $k = 0
        foreach ($f in ($spot | Sort-Object LastWriteTime -Descending | Select-Object -First 40)) {
            try {
                $img = [System.Drawing.Image]::FromFile($f.FullName)
                $ok = $img.Width -ge 1920 -and $img.Width -gt $img.Height
                $img.Dispose()
                if ($ok) { $k++; Add-Wall $f.FullName 'spotlight' "Spotlight $k" }
            } catch { }
            if ($k -ge 16) { break }
        }
    }
    return $items
}

# ---------- cameras the PC already has (go2rtc, e.g. the one inside Afterglow) ----------
# TV Home plays them through TV Link (port 8790 -> go2rtc's RTSP), so no camera logins on the TV.
# (8555 is go2rtc's own WebRTC port, so TV Link must not use it.)
function Test-Go2RtcPort([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { return '' }
        $c.EndConnect($iar)
        $s = $c.GetStream(); $s.ReadTimeout = 1200
        $req = [Text.Encoding]::ASCII.GetBytes("OPTIONS rtsp://127.0.0.1:$port/ RTSP/1.0`r`nCSeq: 1`r`n`r`n")
        $s.Write($req, 0, $req.Length)
        $buf = New-Object byte[] 64
        $n = $s.Read($buf, 0, 64)
        $t = [Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0, $n))
        if ($t -like 'RTSP/1.0*') { return 'rtsp' }
        if ($t -like 'HTTP/*') { return 'http' }
        return ''
    } catch { return '' } finally { $c.Close() }
}
function Get-Go2RtcCams {
    $r = [ordered]@{ port = 8554; api = 1984; user = ''; pass = ''; names = @(); from = ''; src = @{}; ports = @(); rtspOk = $false; apiOk = $false }
    $files = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'go2rtc%'" -ErrorAction Stop)) {
            if ($p.CommandLine -match '(?:-c|-config|--config)\s+"?([^"]+?\.(?:ya?ml|json))"?(\s|$)') { $files += $Matches[1] }
            if ($p.ExecutablePath) { $d = Split-Path $p.ExecutablePath; $files += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^go2rtc.*\.ya?ml$' } | ForEach-Object { $_.FullName }) }
            $r.from = $p.ExecutablePath
        }
    } catch { }
    foreach ($d in @((Join-Path $env:LOCALAPPDATA 'Afterglow\go2rtc'), (Join-Path $env:LOCALAPPDATA 'Afterglow'), (Join-Path $env:ProgramData 'go2rtc'), (Join-Path $env:USERPROFILE 'go2rtc'))) {
        $files += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.ya?ml$' } | ForEach-Object { $_.FullName })
    }
    $names = New-Object System.Collections.ArrayList
    foreach ($f in ($files | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $section = ''
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
            if ($line -match '^([A-Za-z_]+):\s*$') { $section = $Matches[1]; continue }
            if ($line -match '^\S') { $section = ''; continue }
            if ($section -eq 'api' -and $line -match 'listen:\s*"?[^:"]*:(\d+)') { $r.api = [int]$Matches[1] }
            if ($section -eq 'rtsp') {
                if ($line -match 'listen:\s*"?[^:"]*:(\d+)') { $r.port = [int]$Matches[1] }
                if ($line -match '^\s+username:\s*"?([^"]+?)"?\s*$') { $r.user = $Matches[1] }
                if ($line -match '^\s+password:\s*"?([^"]+?)"?\s*$') { $r.pass = $Matches[1] }
            }
            if ($section -eq 'streams' -and $line -match '^\s{1,4}([^\s:#-][^:]*?):\s*(.*)$') {
                $n = $Matches[1].Trim().Trim('"').Trim("'"); $v = $Matches[2].Trim().Trim('"').Trim("'"); $last = $n
                if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
                if ($v -match '^\w+://') { $r.src[$n] = $v }
            } elseif ($section -eq 'streams' -and $line -match '^\s+-\s*"?(\w+://[^"\s]+)' -and $last -and -not $r.src[$last]) { $r.src[$last] = $Matches[1] }
        }
        if (-not $r.from) { $r.from = $f }
    }
    # Which ports the running go2rtc really listens on (its settings file may not say): test each one.
    try {
        $pids = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'go2rtc%'" -ErrorAction Stop | ForEach-Object { [int]$_.ProcessId })
        $ports = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $pids -contains [int]$_.OwningProcess } | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        $r.ports = $ports
        $foundRtsp = $false; $foundApi = $false
        foreach ($pt in $ports) {
            $kind = Test-Go2RtcPort $pt
            if ($kind -eq 'rtsp' -and -not $foundRtsp) { $r.port = $pt; $foundRtsp = $true }
            if ($kind -eq 'http' -and -not $foundApi) { $r.api = $pt; $foundApi = $true }
        }
        $r.rtspOk = $foundRtsp; $r.apiOk = $foundApi
    } catch { }
    # The running go2rtc knows best (streams added in its web page too).
    try {
        $j = Invoke-RestMethod -Uri "http://127.0.0.1:$($r.api)/api/streams" -TimeoutSec 3
        foreach ($n in @($j.PSObject.Properties.Name)) {
            if ($n -and -not $names.Contains($n)) { [void]$names.Add($n) }
            if (-not $r.src[$n]) { $u = @($j.$n.producers | ForEach-Object { $_.url } | Where-Object { $_ -match '^\w+://' }) | Select-Object -First 1; if ($u) { $r.src[$n] = [string]$u } }
        }
    } catch { }
    $r.names = @($names)
    return $r
}

# ---------- tiny web server ----------

# ---------- games: the TV Games folder, and PS3 / Wii U emulators on this PC ----------
# In the user's own folder (C:\Users\<name>\TV Games), not Documents: Documents is often inside OneDrive,
# which would upload every game to the cloud. A "TV Games" shortcut goes on the desktop.
$GamesDir = Join-Path $env:USERPROFILE 'TV Games'
$EmuDir = Join-Path $env:LOCALAPPDATA 'TV Home\Emulators'
# Consoles the TV plays itself (Lemuroid, PPSSPP): folder name -> file types
$GameSystems = [ordered]@{
    'N64' = 'z64|n64|v64'; 'SNES' = 'sfc|smc'; 'NES' = 'nes'; 'Game Boy' = 'gb|gbc'; 'GBA' = 'gba'; 'DS' = 'nds'
    'Mega Drive' = 'md|gen|smd|bin'; 'PS1' = 'chd|pbp|cue'; 'PSP' = 'iso|cso'
}
function New-GamesFolders {
    try {
        foreach ($s in @($GameSystems.Keys) + @('PS3', 'Wii U', 'Saves')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $GamesDir $s)) }
        $readme = Join-Path $GamesDir 'Read me.txt'
        if (-not (Test-Path -LiteralPath $readme)) {
            Set-Content -LiteralPath $readme -Encoding UTF8 -Value @(
                'TV Home: put your own game files here, each in the folder for its console.', '',
                'N64, SNES, NES, Game Boy, GBA, DS, Mega Drive, PS1 and PSP games are copied to the TV',
                '(TV Home > Gaming > Game files) and played there with Lemuroid or PPSSPP.', '',
                'PS3 and Wii U games play on this PC: TV Home starts them here and you play them on the TV with Moonlight.',
                'Zipped games (.zip, .7z) are fine in these folders too.',
                'PS3: one folder per game with PS3_GAME inside.   Wii U: .wua, .wux, .wud or .rpx files.', '',
                'Saves: the save backups made from each TV.')
        }
        $desk = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desk 'TV Games.lnk'
        if ($desk -and -not (Test-Path -LiteralPath $lnk)) {
            $ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($lnk); $sc.TargetPath = $GamesDir; $sc.Description = 'Games for TV Home'; $sc.Save()
        }
        # TV Link 11 made TV Games in Documents: move anything put there, then remove the empty copy.
        $old = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'TV Games'
        if ($old -ne $GamesDir -and (Test-Path -LiteralPath $old)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $old -File -Recurse -ErrorAction SilentlyContinue)) {
                $to = Join-Path $GamesDir $f.FullName.Substring($old.Length + 1)
                if (-not (Test-Path -LiteralPath $to)) { [void](New-Item -ItemType Directory -Force -Path (Split-Path $to)); Move-Item -LiteralPath $f.FullName -Destination $to -ErrorAction SilentlyContinue }
            }
            if (@(Get-ChildItem -LiteralPath $old -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}
function Get-ShortId([string]$s) {
    $md5 = [Security.Cryptography.MD5]::Create()
    ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLower()))) -replace '-', '').Substring(0, 12).ToLower()
}
function Get-TvGames {
    $items = [ordered]@{}
    foreach ($sys in @($GameSystems.Keys)) {
        $rx = '^\.(' + $GameSystems[$sys] + '|zip|7z)$'
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $GamesDir $sys) -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match $rx } | Select-Object -First 600)) {
            $parts = @([pscustomobject]@{ file = $f.Name; path = $f.FullName; size = $f.Length })
            if ($f.Extension -eq '.bin' -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, '.cue')))) { continue }   # part of a .cue game
            if ($f.Extension -eq '.cue') {
                # A .cue game is the .cue plus the .bin files it names; they travel together.
                foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue), 'FILE\s+"([^"]+)"')) {
                    $bp = Join-Path $f.DirectoryName $m.Groups[1].Value
                    if (Test-Path -LiteralPath $bp) { $bi = Get-Item -LiteralPath $bp; $parts += [pscustomobject]@{ file = $bi.Name; path = $bi.FullName; size = $bi.Length } }
                }
            }
            $id = Get-ShortId $f.FullName
            $items[$id] = [pscustomobject]@{ id = $id; name = ([IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '[_]+', ' ').Trim(); system = $sys
                size = [int64]($parts | Measure-Object -Property size -Sum).Sum; parts = $parts }
        }
    }
    $items
}
# PS3 PARAM.SFO: the game's real name (TITLE) and kind (CATEGORY: DG disc, HG installed)
function Read-Sfo([string]$path) {
    $o = @{}
    try {
        $b = [IO.File]::ReadAllBytes($path)
        if ($b.Length -lt 20 -or $b[1] -ne 0x50 -or $b[2] -ne 0x53 -or $b[3] -ne 0x46) { return $o }
        $kt = [BitConverter]::ToUInt32($b, 8); $dt = [BitConverter]::ToUInt32($b, 12); $n = [BitConverter]::ToUInt32($b, 16)
        for ($i = 0; $i -lt $n -and $i -lt 64; $i++) {
            $e = 20 + $i * 16
            $ks = $kt + [BitConverter]::ToUInt16($b, $e); $ke = $ks
            while ($ke -lt $b.Length -and $b[$ke] -ne 0) { $ke++ }
            $key = [Text.Encoding]::ASCII.GetString($b, $ks, $ke - $ks)
            $fmt = [BitConverter]::ToUInt16($b, $e + 2); $len = [BitConverter]::ToUInt32($b, $e + 4); $off = $dt + [BitConverter]::ToUInt32($b, $e + 12)
            if ($fmt -ne 0x0404 -and $off + $len -le $b.Length) { $o[$key] = [Text.Encoding]::UTF8.GetString($b, $off, $len).TrimEnd([char]0).Trim() }
        }
    } catch { }
    $o
}
function Find-Exe([string]$name) {
    $roots = @(@($EmuDir, 3), @([Environment]::GetFolderPath('Desktop'), 2), @((Join-Path $env:USERPROFILE 'Downloads'), 2),
        @([Environment]::GetFolderPath('MyDocuments'), 2), @('C:\Games', 2), @('C:\Emulators', 2), @($env:ProgramFiles, 2), @('C:\', 1), @('D:\', 2), @('E:\', 1))
    foreach ($r in $roots) {
        if (-not $r[0] -or -not (Test-Path -LiteralPath $r[0])) { continue }
        $f = Get-ChildItem -LiteralPath $r[0] -Filter $name -File -Recurse -Depth $r[1] -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    ''
}
function Get-Ps3Games([string]$exe) {
    $list = [ordered]@{}
    function Add-Ps3([string]$eboot, [string]$sfo, [string]$fallback) {
        if (-not (Test-Path -LiteralPath $eboot)) { return }
        $t = Read-Sfo $sfo
        $nm = if ($t['TITLE']) { $t['TITLE'] } else { $fallback }
        $id = Get-ShortId $eboot
        if (-not $list.Contains($id)) { $list[$id] = [pscustomobject]@{ id = $id; name = $nm; path = $eboot } }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $GamesDir 'PS3') -Directory -ErrorAction SilentlyContinue)) {
        Add-Ps3 (Join-Path $d.FullName 'PS3_GAME\USRDIR\EBOOT.BIN') (Join-Path $d.FullName 'PS3_GAME\PARAM.SFO') $d.Name
    }
    if ($exe) {
        $home3 = Split-Path $exe
        # Disc games already added in RPCS3 (its games.yml), and games installed into it (PSN)
        foreach ($yml in @((Join-Path $home3 'config\games.yml'), (Join-Path $home3 'games.yml'))) {
            foreach ($ln in @(Get-Content -LiteralPath $yml -ErrorAction SilentlyContinue)) {
                if ($ln -match '^\s*[A-Z]{4}\d{5}:\s*(.+?)\s*$') {
                    $gp = $Matches[1].Trim('"', "'").Replace('/', '\')
                    Add-Ps3 (Join-Path $gp 'PS3_GAME\USRDIR\EBOOT.BIN') (Join-Path $gp 'PS3_GAME\PARAM.SFO') (Split-Path $gp -Leaf)
                    Add-Ps3 (Join-Path $gp 'USRDIR\EBOOT.BIN') (Join-Path $gp 'PARAM.SFO') (Split-Path $gp -Leaf)
                }
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $home3 'dev_hdd0\game') -Directory -ErrorAction SilentlyContinue)) {
            $sfo = Join-Path $d.FullName 'PARAM.SFO'
            if ((Read-Sfo $sfo)['CATEGORY'] -eq 'HG') { Add-Ps3 (Join-Path $d.FullName 'USRDIR\EBOOT.BIN') $sfo $d.Name }
        }
    }
    @($list.Values)
}
function Get-WiiuGames([string]$exe) {
    $dirs = @(Join-Path $GamesDir 'Wii U')
    if ($exe) {
        # Cemu's own game folders (Options > General settings > Game paths)
        foreach ($sx in @((Join-Path (Split-Path $exe) 'settings.xml'), (Join-Path $env:APPDATA 'Cemu\settings.xml'))) {
            try { if (Test-Path -LiteralPath $sx) { $x = [xml](Get-Content -LiteralPath $sx -Raw); foreach ($e in @($x.content.GamePaths.Entry)) { $t = if ($e -is [string]) { $e } else { $e.InnerText }; if ($t) { $dirs += $t } } } } catch { }
        }
    }
    $list = [ordered]@{}
    foreach ($d in ($dirs | Select-Object -Unique)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(wua|wux|wud|wuhb)$' -or ($_.Extension -eq '.rpx' -and $_.Directory.Name -eq 'code') } | Select-Object -First 300)) {
            $nm = if ($f.Extension -eq '.rpx') { $f.Directory.Parent.Name } else { [IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $id = Get-ShortId $f.FullName
            if (-not $list.Contains($id)) { $list[$id] = [pscustomobject]@{ id = $id; name = ($nm -replace '[_]+', ' ').Trim(); path = $f.FullName } }
        }
    }
    @($list.Values)
}
function Get-Emus {
    $r = [ordered]@{}
    $p3 = Find-Exe 'rpcs3.exe'
    $r['rpcs3'] = [pscustomobject]@{ id = 'rpcs3'; name = 'PS3'; app = 'RPCS3'; exe = $p3; games = @(Get-Ps3Games $p3) }
    $cu = Find-Exe 'Cemu.exe'
    $r['cemu'] = [pscustomobject]@{ id = 'cemu'; name = 'Wii U'; app = 'Cemu'; exe = $cu; games = @(Get-WiiuGames $cu) }
    $r
}
# Keeps TV Link up to date by itself: the newest TV Link is published next to the TV's updates. A newer
# one that's whole and valid PowerShell replaces this copy and starts; it then takes over from this one.
$selfUpdateText = {
    param($cache)
    if ($env:GITHUB_ACTIONS) { return }
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $home2 = Join-Path $env:LOCALAPPDATA 'TVLink'
        $vbs = Join-Path $home2 'run-hidden.vbs'
        if (-not (Test-Path -LiteralPath $vbs)) { return }      # not installed the usual way (a test copy, say)
        $tmp = Join-Path $env:TEMP 'TVLink.new.ps1'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/aaron6k-boop/tv-home-updates/main/TV-Link/TVLink.ps1' -OutFile $tmp -UseBasicParsing -TimeoutSec 90 -Headers @{ 'Cache-Control' = 'no-cache' }
        $txt = [IO.File]::ReadAllText($tmp)
        if ($txt.Length -lt 20000 -or $txt -notmatch '\$LinkVersion\s*=\s*(\d+)') { return }
        $newVer = [int]$Matches[1]
        if ($newVer -le [int]$cache.linkVersion) { return }
        $errs = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$tok, [ref]$errs)
        if ($errs -and $errs.Count) { return }
        Copy-Item -LiteralPath $tmp -Destination (Join-Path $home2 'TVLink.ps1') -Force
        $cache.updatedTo = $newVer
        Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
    } catch { }
}.ToString()

# Installs an emulator from its official GitHub releases into %LOCALAPPDATA%\TV Home\Emulators (asked for from the TV).
$installText = {
    param($cache, $id)
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $dest = Join-Path $cache.emuDir $id
    $tmp = Join-Path $env:TEMP ('tvhome-' + $id)
    try {
        $cache.emuState[$id] = 'Finding the newest version'
        $repo = if ($id -eq 'rpcs3') { 'RPCS3/rpcs3-binaries-win' } else { 'cemu-project/Cemu' }
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'TVLink' } -TimeoutSec 30
        $asset = if ($id -eq 'rpcs3') { @($rel.assets | Where-Object { $_.name -match 'win64.*\.7z$' })[0] } else { @($rel.assets | Where-Object { $_.name -match 'windows-x64\.zip$' })[0] }
        if (-not $asset) { throw 'there was no Windows download in the newest release' }
        [void](New-Item -ItemType Directory -Force -Path $tmp)
        $file = Join-Path $tmp $asset.name
        $cache.emuState[$id] = 'Downloading (' + [Math]::Max(1, [Math]::Round($asset.size / 1MB)) + ' MB)'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'TVLink' } -TimeoutSec 900
        $cache.emuState[$id] = 'Unpacking'
        [void](New-Item -ItemType Directory -Force -Path $dest)
        if ($file -match '\.zip$') { Expand-Archive -LiteralPath $file -DestinationPath $dest -Force }
        else {
            $ok = $false
            $tar = Join-Path $env:WINDIR 'System32\tar.exe'
            if (Test-Path -LiteralPath $tar) { & $tar -xf $file -C $dest 2>$null; $ok = ($LASTEXITCODE -eq 0) }
            if (-not $ok) {
                foreach ($z in @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))) {
                    if (Test-Path -LiteralPath $z) { & $z x -y ('-o' + $dest) $file | Out-Null; $ok = ($LASTEXITCODE -eq 0); break }
                }
            }
            if (-not $ok) { throw 'unpacking it needs Windows 11 or 7-Zip' }
        }
        $cache.emuState[$id] = 'done'
        $cache.emusDirty = $true
    } catch { $cache.emuState[$id] = 'error: ' + $_.Exception.Message }
    finally { try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}.ToString()

$handler = {
    param($client, $info, $we, $walls, $cache)
    # ---- temperatures in C; $null when this PC doesn't report one ----
    # Windows' own GPU temperature (the one Task Manager shows), for any make of graphics card.
    function Get-WinGpuTemp {
        try {
            if (-not ('TvLinkGpu' -as [type])) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TvLinkGpu {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct ADAPTERINFO { public uint hAdapter; public LUID Luid; public uint NumOfSources; public int Precise; }
    [StructLayout(LayoutKind.Sequential)] struct ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }
    [StructLayout(LayoutKind.Sequential)] struct QUERYADAPTERINFO { public uint hAdapter; public int Type; public IntPtr pData; public uint DataSize; }
    [StructLayout(LayoutKind.Sequential)] struct PERFDATA { public uint PhysicalAdapterIndex; public ulong MemFreq; public ulong MaxMemFreq; public ulong MaxMemFreqOC; public ulong MemBandwidth; public ulong PcieBandwidth; public uint FanRPM; public uint Power; public uint Temperature; public byte PowerStateOverride; }
    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref ENUMADAPTERS2 p);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QUERYADAPTERINFO p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref uint h);
    public static double MaxTemp() {
        ENUMADAPTERS2 e = new ENUMADAPTERS2();
        if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return -1;
        int sz = Marshal.SizeOf(typeof(ADAPTERINFO));
        e.pAdapters = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
        double best = -1;
        try {
            if (D3DKMTEnumAdapters2(ref e) != 0) return -1;
            int psz = Marshal.SizeOf(typeof(PERFDATA));
            for (int i = 0; i < e.NumAdapters; i++) {
                ADAPTERINFO a = (ADAPTERINFO)Marshal.PtrToStructure(new IntPtr(e.pAdapters.ToInt64() + (long)i * sz), typeof(ADAPTERINFO));
                IntPtr buf = Marshal.AllocHGlobal(psz);
                try {
                    Marshal.StructureToPtr(new PERFDATA(), buf, false);
                    QUERYADAPTERINFO q = new QUERYADAPTERINFO();
                    q.hAdapter = a.hAdapter; q.Type = 62; q.pData = buf; q.DataSize = (uint)psz;
                    if (D3DKMTQueryAdapterInfo(ref q) == 0) {
                        PERFDATA pd = (PERFDATA)Marshal.PtrToStructure(buf, typeof(PERFDATA));
                        double t = pd.Temperature / 10.0;
                        if (t > 5 && t < 130 && t > best) best = t;
                    }
                } finally { Marshal.FreeHGlobal(buf); }
                uint h = a.hAdapter; D3DKMTCloseAdapter(ref h);
            }
        } finally { Marshal.FreeHGlobal(e.pAdapters); }
        return best;
    }
}
"@
            }
            $t = [TvLinkGpu]::MaxTemp()
            if ($t -gt 0) { return [math]::Round($t) }
        } catch { }
        return $null
    }
    function Get-Temps($info, [double]$smiTemp) {
        $cpu = $null; $gpu = $null
        # LibreHardwareMonitor / OpenHardwareMonitor, when one is running, publish every sensor.
        foreach ($ns in @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor')) {
            try {
                $s = @(Get-CimInstance -Namespace $ns -ClassName Sensor -Filter "SensorType='Temperature'" -OperationTimeoutSec 2 -ErrorAction Stop)
                if ($s.Count) {
                    $c = $s | Where-Object { $_.Identifier -match '/(intelcpu|amdcpu)/' -and $_.Name -match 'Package|Tctl|Tdie|CCD' } | Sort-Object Value -Descending | Select-Object -First 1
                    if (-not $c) { $c = $s | Where-Object { $_.Identifier -match '/(intelcpu|amdcpu)/' } | Sort-Object Value -Descending | Select-Object -First 1 }
                    $g = $s | Where-Object { $_.Identifier -match 'gpu' -and $_.Name -match 'Core|GPU' -and $_.Name -notmatch 'Hot ?Spot|Memory' } | Select-Object -First 1
                    if ($c) { $cpu = [math]::Round([double]$c.Value) }
                    if ($g) { $gpu = [math]::Round([double]$g.Value) }
                    break
                }
            } catch { }
        }
        # LibreHardwareMonitor's own web server (Options > Remote Web Server > Run), for versions that
        # don't publish to WMI.
        if ($null -eq $cpu) {
            try {
                $j = Invoke-RestMethod -Uri 'http://127.0.0.1:8085/data.json' -TimeoutSec 2 -ErrorAction Stop
                $found = New-Object System.Collections.ArrayList
                $walk = $null
                $walk = {
                    param($n, [bool]$cpuSide, [bool]$gpuSide)
                    if ($null -eq $n) { return }
                    $img = [string]$n.ImageURL; $sid = [string]$n.SensorId
                    if ($img -match 'cpu' -or $sid -match '/(amdcpu|intelcpu)/') { $cpuSide = $true }
                    if ($img -match '(nvidia|ati|amd|intel|gpu)\.png' -and $img -notmatch 'cpu' -or $sid -match '/gpu') { $gpuSide = $true }
                    $v = [string]$n.Value
                    if ($v -match '^\s*(-?[0-9]+(?:[.,][0-9]+)?)\s*\W{0,2}C\s*$' -and ([string]$n.Type -eq 'Temperature' -or -not $n.Type)) {
                        [void]$found.Add([pscustomobject]@{ name = [string]$n.Text; t = [double]($Matches[1] -replace ',', '.'); cpu = $cpuSide; gpu = $gpuSide })
                    }
                    foreach ($ch in @($n.Children)) { & $walk $ch $cpuSide $gpuSide }
                }
                & $walk $j $false $false
                $c = $found | Where-Object { $_.cpu -and $_.name -match 'Package|Tctl|Tdie|CCD' } | Sort-Object t -Descending | Select-Object -First 1
                if (-not $c) { $c = $found | Where-Object { $_.cpu } | Sort-Object t -Descending | Select-Object -First 1 }
                if ($c -and $c.t -gt 5 -and $c.t -lt 120) { $cpu = [math]::Round($c.t) }
                if ($null -eq $gpu) {
                    $g = $found | Where-Object { $_.gpu -and $_.name -match 'Core|GPU' -and $_.name -notmatch 'Hot ?Spot|Memory' } | Select-Object -First 1
                    if ($g -and $g.t -gt 5 -and $g.t -lt 130) { $gpu = [math]::Round($g.t) }
                }
            } catch { }
        }
        if ($null -eq $gpu -and $smiTemp -gt 0) { $gpu = [math]::Round($smiTemp) }
        if ($null -eq $gpu) { $gpu = Get-WinGpuTemp }
        # The motherboard's own temperature sensors (ACPI thermal zones), when it reports real ones.
        if ($null -eq $cpu) {
            try {
                $z = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop |
                    ForEach-Object { if ($_.HighPrecisionTemperature) { $_.HighPrecisionTemperature / 10.0 - 273.15 } else { [double]$_.Temperature - 273.15 } } |
                    Where-Object { $_ -gt 15 -and $_ -lt 110 -and [math]::Abs($_ - 27.85) -gt 0.2 })
                if ($z.Count) { $cpu = [math]::Round(($z | Measure-Object -Maximum).Maximum) }
            } catch { }
        }
        return @{ cpu = $cpu; gpu = $gpu }
    }
    function Get-Stats($info) {
        $cpuPct = 0
        try { $cpuPct = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch { }
        $gpuPct = $null; $smiTemp = 0
        if ($info.smi) {
            $v = & $info.smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($v) {
                $f = $v -split ','
                $gpuPct = [double]$f[0].Trim()
                if ($f.Count -gt 1) { try { $smiTemp = [double]$f[1].Trim() } catch { } }
            }
        }
        if ($null -eq $gpuPct) {
            # Any make of graphics card: the busiest 3D engine, as in Task Manager.
            try {
                $eng = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -match 'engtype_3D' })
                $byGpu = @{}
                foreach ($e in $eng) {
                    $k = if ($e.Name -match 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)') { $Matches[1] } else { 'gpu' }
                    $byGpu[$k] = [double]$byGpu[$k] + [double]$e.UtilizationPercentage
                }
                if ($byGpu.Count) { $gpuPct = [math]::Min(100, ($byGpu.Values | Measure-Object -Maximum).Maximum) }
            } catch { }
        }
        if ($null -eq $gpuPct) { $gpuPct = 0 }
        $temps = Get-Temps $info $smiTemp
        $os = Get-CimInstance Win32_OperatingSystem
        $ramTotal = [double]$os.TotalVisibleMemorySize
        $ramPct = if ($ramTotal) { 100 * ($ramTotal - [double]$os.FreePhysicalMemory) / $ramTotal } else { 0 }
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $diskPct = if ($disk.Size) { 100 * ($disk.Size - $disk.FreeSpace) / $disk.Size } else { 0 }
        [ordered]@{
            app  = 'TVLink'; name = $info.name; mac = $info.mac; version = 12
            cpu  = @{ pct = [math]::Round($cpuPct); name = $info.cpu; temp = $temps.cpu }
            gpu  = @{ pct = [math]::Round($gpuPct); name = $info.gpu; temp = $temps.gpu }
            ram  = @{ pct = [math]::Round($ramPct); totalGB = [math]::Round($ramTotal / 1MB) }
            disk = @{ pct = [math]::Round($diskPct); label = 'C:'; totalGB = [math]::Round($disk.Size / 1GB) }
        }
    }
    function Send($stream, [int]$code, [string]$type, [byte[]]$body, [string]$extra = '') {
        $reason = @{ 200 = 'OK'; 204 = 'No Content'; 404 = 'Not Found'; 500 = 'Error' }[$code]
        $head = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nCache-Control: no-store`r`nConnection: close`r`n$extra`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        if ($body.Length) { $stream.Write($body, 0, $body.Length) }
    }
    # The PC's wallpaper right now: Wallpaper Engine's (asked directly with its documented
    # "-control getWallpaper"), otherwise Windows' own wallpaper picture at full resolution.
    function Get-Current($we) {
        if ($we.exe) {
            $p = ''
            try {
                $tmp = [IO.Path]::GetTempFileName()
                $pr = Start-Process -FilePath $we.exe -ArgumentList @('-control', 'getWallpaper') -RedirectStandardOutput $tmp -WindowStyle Hidden -PassThru
                if (-not $pr.WaitForExit(4000)) { try { $pr.Kill() } catch { } }
                $p = ('' + (Get-Content $tmp -Raw -ErrorAction SilentlyContinue)).Trim().Trim('"')
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            } catch { }
            if ($p) {
                $norm = ($p -replace '/', '\').ToLower()
                foreach ($w in $we.items.Values) {
                    $d = $w.dir.ToLower().TrimEnd('\')
                    if ($norm -eq $d -or $norm.StartsWith($d + '\')) {
                        $isVideo = ($w.type -eq 'video' -and $w.file)
                        $full = $(if ($isVideo) { Join-Path $w.dir $w.file } else { Join-Path $w.dir $w.preview })
                        return [ordered]@{ source = 'we'; id = $w.id; title = $w.title; type = $(if ($isVideo) { 'video' } else { 'image' }); full = [bool]$isVideo; path = $full }
                    }
                }
                if ($norm -match '\.(mp4|webm)$' -and (Test-Path -LiteralPath $p)) {
                    $fi = Get-Item -LiteralPath $p
                    return [ordered]@{ source = 'we'; id = 'file-' + $fi.LastWriteTimeUtc.Ticks; title = $fi.BaseName; type = 'video'; full = $true; path = $p }
                }
            }
        }
        # Afterglow draws its own wallpaper; the newest of its TV backgrounds is the one to match.
        $ag = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Afterglow\tv-backgrounds') -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png|webp|mp4|webm)$' -and $_.Length -gt 30KB } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($ag.Count) {
            $f = $ag[0]; $vid = $f.Extension -match 'mp4|webm'
            return [ordered]@{ source = 'afterglow'; id = 'ag-' + $f.LastWriteTimeUtc.Ticks + '-' + $f.Length; title = 'Afterglow'; type = $(if ($vid) { 'video' } else { 'image' }); full = $true; path = $f.FullName }
        }
        $win = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
        if (Test-Path -LiteralPath $win) {
            $fi = Get-Item -LiteralPath $win
            return [ordered]@{ source = 'windows'; id = 'win-' + $fi.LastWriteTimeUtc.Ticks; title = 'Windows wallpaper'; type = 'image'; full = $true; path = $win }
        }
        return [ordered]@{ source = 'none'; id = ''; title = ''; type = ''; full = $false; path = '' }
    }
    # ---- what's playing on the PC (Windows media controls: Spotify, YouTube in Chrome/Edge, ...) ----
    function Get-MediaSession {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $mgr = Wait-WinRt ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if (-not $mgr) { return $null }
        $best = $null
        foreach ($s in @($mgr.GetSessions())) { if ([string]$s.GetPlaybackInfo().PlaybackStatus -eq 'Playing') { $best = $s; break } }
        if (-not $best) { $best = $mgr.GetCurrentSession() }
        return $best
    }
    function Wait-WinRt($op, [Type]$type) {
        $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $task = $m.MakeGenericMethod($type).Invoke($null, @($op))
        if (-not $task.Wait(3000)) { return $null }
        return $task.Result
    }
    function Get-AppName([string]$id) {
        $n = ($id -split '!')[0] -replace '\.exe$', ''
        $known = @{ 'chrome' = 'Chrome'; 'msedge' = 'Edge'; 'firefox' = 'Firefox'; 'spotify' = 'Spotify'; 'vlc' = 'VLC'; 'opera' = 'Opera'; 'brave' = 'Brave' }
        foreach ($k in $known.Keys) { if ($n -match $k) { return $known[$k] } }
        if ($n -match 'ZuneMusic') { return 'Media Player' }
        if ($n -match 'Spotify') { return 'Spotify' }
        return (($n -split '[._]') | Where-Object { $_ } | Select-Object -Last 1)
    }
    function Get-Media($cache) {
        $out = [ordered]@{ status = 'none'; title = ''; artist = ''; app = ''; position = 0; duration = 0; art = ''; artError = '' }
        try {
            $s = Get-MediaSession
            if (-not $s) { return $out }
            $props = Wait-WinRt ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            $pb = $s.GetPlaybackInfo()
            $out.status = ([string]$pb.PlaybackStatus).ToLower()
            $out.shuffle = [bool]$pb.IsShuffleActive
            $out.canShuffle = [bool]$pb.Controls.IsShuffleEnabled
            $out.app = Get-AppName $s.SourceAppUserModelId
            if ($props) { $out.title = [string]$props.Title; $out.artist = [string]$props.Artist; if (-not $out.artist) { $out.artist = [string]$props.AlbumArtist } }
            $tl = $s.GetTimelineProperties()
            if ($tl) { $out.position = [int64]$tl.Position.TotalMilliseconds; $out.duration = [int64]$tl.EndTime.TotalMilliseconds }
            $key = ($out.app + '|' + $out.title + '|' + $out.artist).GetHashCode().ToString('x')
            if ($props -and $props.Thumbnail) {
                if ($cache.artKey -ne $key) {
                    try {
                        $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
                        $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
                        $rs = Wait-WinRt ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
                        if ($rs) {
                            $size = [uint32]$rs.Size
                            $dr = [Windows.Storage.Streams.DataReader]::new($rs.GetInputStreamAt(0))
                            $null = Wait-WinRt ($dr.LoadAsync($size)) ([uint32])
                            $bytes = New-Object byte[] $size
                            $dr.ReadBytes($bytes)
                            if ($bytes.Length -gt 100) { $cache.art = $bytes; $cache.artKey = $key }
                        }
                    } catch { $out.artError = $_.Exception.Message }
                }
                if ($cache.artKey -eq $key) { $out.art = $key }
            }
        } catch { }
        return $out
    }
    # ---- the picture and sound level of what's playing, for the circle on the TV's Music screen ----
    function Ensure-Cap {
        if ('TvLinkCap' -as [type]) { return }
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class TvLinkMMDevEnum { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvLinkDevEnum { int NotUsed(); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out ITvLinkDev dev); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvLinkDev { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvLinkMeter {
    [PreserveSig] int GetPeakValue(out float peak);
    [PreserveSig] int GetMeteringChannelCount(out int n);
    [PreserveSig] int GetChannelsPeakValues(int n, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] float[] v);
}
public class TvLinkMeter {
    ITvLinkMeter m; int age;
    // Loudness of what the PC is playing right now (0-1): overall, left, right.
    public float[] Read() {
        try {
            if (m == null || ++age > 400) {
                age = 0; m = null;
                ITvLinkDevEnum en = (ITvLinkDevEnum)new TvLinkMMDevEnum(); ITvLinkDev d;
                if (en.GetDefaultAudioEndpoint(0, 1, out d) != 0 || d == null) return null;
                Guid g = typeof(ITvLinkMeter).GUID; object o;
                if (d.Activate(ref g, 23, IntPtr.Zero, out o) != 0 || o == null) return null;
                m = (ITvLinkMeter)o;
            }
            int n; m.GetMeteringChannelCount(out n); if (n < 1) n = 1; if (n > 8) n = 8;
            float[] v = new float[n]; m.GetChannelsPeakValues(n, v);
            float p; m.GetPeakValue(out p);
            return new float[] { p, v[0], n > 1 ? v[1] : v[0] };
        } catch { m = null; return null; }
    }
}
public static class TvLinkCap {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONINFO i);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct MONINFO { public int Size; public RECT Mon; public RECT Work; public int Flags; }
    static bool dpi;
    static ImageCodecInfo jpg;
    static EncoderParameters ep;
    static void Dpi() { if (!dpi) { SetProcessDPIAware(); dpi = true; } }
    // The window's place on screen, and the screen it's on: x, y, w, h, monX, monY, monW, monH, minimised
    public static int[] Where(IntPtr h) {
        Dpi(); RECT r; if (!GetWindowRect(h, out r)) return null;
        MONINFO mi = new MONINFO(); mi.Size = Marshal.SizeOf(typeof(MONINFO));
        IntPtr mon = MonitorFromWindow(h, 2);
        if (!GetMonitorInfo(mon, ref mi)) return null;
        return new int[] { r.L, r.T, r.R - r.L, r.B - r.T, mi.Mon.L, mi.Mon.T, mi.Mon.R - mi.Mon.L, mi.Mon.B - mi.Mon.T, IsIconic(h) ? 1 : 0 };
    }
    public static byte[] Grab(int x, int y, int w, int h, int outW) {
        Dpi();
        if (w < 16 || h < 16) return null;
        int outH = (int)((long)h * outW / w);
        using (Bitmap full = new Bitmap(w, h))
        using (Graphics g = Graphics.FromImage(full)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            using (Bitmap small = new Bitmap(outW, outH))
            using (Graphics g2 = Graphics.FromImage(small)) {
                g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
                g2.DrawImage(full, 0, 0, outW, outH);
                if (jpg == null) {
                    foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) if (c.MimeType == "image/jpeg") jpg = c;
                    ep = new EncoderParameters(1);
                    ep.Param[0] = new EncoderParameter(Encoder.Quality, 70L);
                }
                using (MemoryStream ms = new MemoryStream()) { small.Save(ms, jpg, ep); return ms.ToArray(); }
            }
        }
    }
}
"@
    }
    # ---- the sound the PC is playing, sent to the TV (Windows' "loopback" recording of the speakers) ----
    function Ensure-Audio {
        if ('TvLinkAudio' -as [type]) { return }
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class TvAudEnum { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvAudEnum { int NotUsed(); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out ITvAudDev dev); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvAudDev { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvAudClient {
    [PreserveSig] int Initialize(int shareMode, int flags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    [PreserveSig] int GetBufferSize(out uint frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long def, out long min);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr h);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITvAudCapture {
    [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devPos, out long qpcPos);
    [PreserveSig] int ReleaseBuffer(int frames);
    [PreserveSig] int GetNextPacketSize(out int frames);
}
public static class TvLinkAudio {
    static short Clamp(float v) { int x = (int)(v * 32767f); if (x > 32767) x = 32767; if (x < -32768) x = -32768; return (short)x; }
    static void Put(byte[] b, int i, short v) { b[i] = (byte)v; b[i + 1] = (byte)(v >> 8); }
    public static byte[] Header(int rate) {
        MemoryStream ms = new MemoryStream(); BinaryWriter w = new BinaryWriter(ms);
        w.Write(new byte[] { 82, 73, 70, 70 }); w.Write(unchecked((int)0xFFFFFFFF));
        w.Write(new byte[] { 87, 65, 86, 69, 102, 109, 116, 32 }); w.Write(16); w.Write((short)1); w.Write((short)2);
        w.Write(rate); w.Write(rate * 4); w.Write((short)4); w.Write((short)16);
        w.Write(new byte[] { 100, 97, 116, 97 }); w.Write(unchecked((int)0x7FFFFFFF)); w.Flush();
        return ms.ToArray();
    }
    // Sends what the PC is playing as 16-bit stereo WAV until the TV hangs up. Returns why it stopped.
    public static string Pump(Stream outp, int maxMinutes) {
        ITvAudEnum en = (ITvAudEnum)new TvAudEnum(); ITvAudDev dev;
        int hr = en.GetDefaultAudioEndpoint(0, 1, out dev); if (hr != 0 || dev == null) return "no speakers " + hr;
        Guid g = typeof(ITvAudClient).GUID; object o;
        hr = dev.Activate(ref g, 23, IntPtr.Zero, out o); if (hr != 0) return "activate " + hr;
        ITvAudClient ac = (ITvAudClient)o;
        IntPtr fmt; hr = ac.GetMixFormat(out fmt); if (hr != 0) return "format " + hr;
        int tag = Marshal.ReadInt16(fmt, 0) & 0xFFFF, ch = Marshal.ReadInt16(fmt, 2), rate = Marshal.ReadInt32(fmt, 4), bits = Marshal.ReadInt16(fmt, 14);
        bool isFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(fmt, 24) == 3);
        hr = ac.Initialize(0, 0x00020000, 2000000, 0, fmt, IntPtr.Zero);
        if (hr != 0) { Marshal.FreeCoTaskMem(fmt); return "init " + hr; }
        Guid gc = typeof(ITvAudCapture).GUID; object oc; hr = ac.GetService(ref gc, out oc);
        if (hr != 0) { Marshal.FreeCoTaskMem(fmt); return "service " + hr; }
        ITvAudCapture cap = (ITvAudCapture)oc;
        byte[] h = Header(rate); outp.Write(h, 0, h.Length); outp.Flush();
        ac.Start();
        DateTime until = DateTime.Now.AddMinutes(maxMinutes);
        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        long framesOut = 0;
        byte[] buf = new byte[rate * 4];
        float[] fb = new float[0]; short[] sb = new short[0];
        try {
            while (DateTime.Now < until) {
                Thread.Sleep(10);
                int got = 0, next;
                while (cap.GetNextPacketSize(out next) == 0 && next > 0) {
                    IntPtr data; int frames, flags; long dp, qp;
                    if (cap.GetBuffer(out data, out frames, out flags, out dp, out qp) != 0) break;
                    int need = frames * 4; if (buf.Length < need) buf = new byte[need];
                    if ((flags & 2) != 0 || data == IntPtr.Zero) Array.Clear(buf, 0, need);
                    else if (isFloat && bits == 32) {
                        int n = frames * ch; if (fb.Length < n) fb = new float[n]; Marshal.Copy(data, fb, 0, n);
                        for (int i = 0; i < frames; i++) { float l = fb[i * ch], r = ch > 1 ? fb[i * ch + 1] : l; Put(buf, i * 4, Clamp(l)); Put(buf, i * 4 + 2, Clamp(r)); }
                    } else if (bits == 16) {
                        int n = frames * ch; if (sb.Length < n) sb = new short[n]; Marshal.Copy(data, sb, 0, n);
                        for (int i = 0; i < frames; i++) { short l = sb[i * ch], r = ch > 1 ? sb[i * ch + 1] : l; Put(buf, i * 4, l); Put(buf, i * 4 + 2, r); }
                    } else Array.Clear(buf, 0, need);
                    cap.ReleaseBuffer(frames);
                    outp.Write(buf, 0, need); framesOut += frames; got += frames;
                }
                // Nothing playing: Windows sends nothing, so send quiet to keep the TV's player going.
                long due = (long)(sw.Elapsed.TotalSeconds * rate);
                if (got == 0 && due - framesOut > rate / 20) {
                    int fill = (int)Math.Min(due - framesOut, rate / 5), n = fill * 4;
                    if (buf.Length < n) buf = new byte[n];
                    Array.Clear(buf, 0, n); outp.Write(buf, 0, n); framesOut += fill;
                }
                if (framesOut < due - rate * 2) framesOut = due - rate;   // fell behind (TV slow to read): don't rush silence
                outp.Flush();
            }
        } catch (Exception e) { return "ended: " + e.Message; }
        finally { try { ac.Stop(); } catch { } Marshal.FreeCoTaskMem(fmt); }
        return "done";
    }
}
"@
    }
    # The window that's playing a video (a browser or VLC), found by the title Windows' media controls report.
    # Music-only sites are left out (they get the cover picture instead), and so are sites that block
    # screen pictures (Netflix and friends show up black).
    function Find-VideoWindow($cache, $m) {
        if (-not $m) { $m = Get-Media $cache }
        $t = [string]$m.title
        if (-not $t -or $m.app -notmatch '^(Chrome|Edge|Firefox|Opera|Brave|VLC)$') { return $null }
        $k = $m.app + '|' + $t
        $hit = $cache.vidWin
        if (-not $hit -or $hit.key -ne $k -or ((Get-Date) - $hit.at).TotalSeconds -gt 6) {
            $p = Get-Process | Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
            $ok = $p -and ($p.MainWindowTitle -notmatch 'YouTube Music|Spotify|SoundCloud|Deezer|TIDAL|Apple Music|Amazon Music|Netflix|Disney\+|Prime Video|Apple TV|NOW\b|BBC iPlayer')
            $hit = @{ key = $k; at = Get-Date; pid = $(if ($ok) { $p.Id } else { 0 }); h = $(if ($ok) { $p.MainWindowHandle } else { [IntPtr]::Zero }) }
            $cache.vidWin = $hit
        }
        if (-not $hit.pid) { return $null }
        return $hit
    }
    # Make that video full screen (most video sites and VLC use F), unless it already is.
    function Set-VideoFull($cache, $win) {
        Ensure-Cap
        $w = [TvLinkCap]::Where($win.h)
        if (-not $w) { return $false }
        $full = ($w[0] -le $w[4] -and $w[1] -le $w[5] -and $w[2] -ge $w[6] -and $w[3] -ge $w[7] -and $w[2] -le $w[6] + 2 -and $w[3] -le $w[7] + 2)
        if ($full) { return $true }
        $ws = New-Object -ComObject WScript.Shell
        if ($ws.AppActivate([int]$win.pid)) { Start-Sleep -Milliseconds 350; $ws.SendKeys('f'); Start-Sleep -Milliseconds 700; return $true }
        return $false
    }
    function SendJson($stream, $obj) { Send $stream 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5 -Compress))) }
    function SendFile($stream, [string]$path, [string]$range = '') {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Send $stream 404 'text/plain' ([byte[]]@()); return }
        $ext = [IO.Path]::GetExtension($path).ToLower()
        $type = @{ '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.mp4' = 'video/mp4'; '.webm' = 'video/webm' }[$ext]
        if (-not $type) { $type = 'application/octet-stream' }
        $fs = [IO.File]::OpenRead($path)
        try {
            $len = $fs.Length
            if ($range -match '^bytes=(\d*)-(\d*)$' -and ($Matches[1] -or $Matches[2])) {
                $from = $(if ($Matches[1]) { [int64]$Matches[1] } else { $len - [int64]$Matches[2] })
                $to = $(if ($Matches[1] -and $Matches[2]) { [Math]::Min([int64]$Matches[2], $len - 1) } else { $len - 1 })
                if ($from -lt 0) { $from = 0 }
                $count = $to - $from + 1
                $head = "HTTP/1.1 206 Partial Content`r`nContent-Type: $type`r`nAccept-Ranges: bytes`r`nContent-Range: bytes $from-$to/$len`r`nContent-Length: $count`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                $hb = [Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length)
                [void]$fs.Seek($from, 'Begin')
                $buf = New-Object byte[] 65536
                while ($count -gt 0) { $n = $fs.Read($buf, 0, [int][Math]::Min(65536, $count)); if ($n -le 0) { break }; $stream.Write($buf, 0, $n); $count -= $n }
            } else {
                $head = "HTTP/1.1 200 OK`r`nContent-Type: $type`r`nAccept-Ranges: bytes`r`nContent-Length: $len`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
                $hb = [Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length)
                $fs.CopyTo($stream, 65536)
            }
        } finally { $fs.Dispose() }
    }
    try {
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        # The request head, read byte by byte so a body (a save file sent from the TV) is left untouched after it.
        $hbuf = New-Object IO.MemoryStream
        while ($hbuf.Length -lt 16384) {
            $b1 = $stream.ReadByte(); if ($b1 -lt 0) { break }
            $hbuf.WriteByte([byte]$b1)
            $hn = [int]$hbuf.Length
            if ($hn -ge 4) { $ha = $hbuf.GetBuffer(); if ($ha[$hn - 1] -eq 10 -and $ha[$hn - 2] -eq 13 -and $ha[$hn - 3] -eq 10 -and $ha[$hn - 4] -eq 13) { break } }
        }
        $hlines = [Text.Encoding]::ASCII.GetString($hbuf.ToArray()) -split "`r`n"
        $line = $hlines[0]
        $range = ''; $clen = [int64]0
        for ($hi = 1; $hi -lt $hlines.Count; $hi++) {
            if ($hlines[$hi] -match '^Range:\s*(.+)$') { $range = $Matches[1].Trim() }
            elseif ($hlines[$hi] -match '^Content-Length:\s*(\d+)') { $clen = [int64]$Matches[1] }
        }
        if (-not $line) { return }
        $parts = $line.Split(' ')
        if ($parts.Count -lt 2) { return }
        $method = $parts[0]; $path = [Uri]::UnescapeDataString(($parts[1] -split '\?')[0])
        $query = @{}
        if ($parts[1].Contains('?')) {
            foreach ($kv in $parts[1].Substring($parts[1].IndexOf('?') + 1).Split('&')) {
                $qi = $kv.IndexOf('=')
                if ($qi -gt 0) { $query[[Uri]::UnescapeDataString($kv.Substring(0, $qi))] = [Uri]::UnescapeDataString($kv.Substring($qi + 1).Replace('+', ' ')) }
            }
        }
        if ($method -eq 'OPTIONS') { Send $stream 204 'text/plain' ([byte[]]@()); return }
        # ---- games: the TV Games folder (copied to the TV), save backups, PS3 / Wii U on this PC ----
        if ($path -eq '/games') {
            $gl = @(@($cache.games.Values) | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; system = $_.system; size = $_.size; parts = @($_.parts | ForEach-Object { $_.file }) } })
            SendJson $stream ([ordered]@{ folder = $cache.gamesDir; items = $gl }); return
        }
        if ($path -match '^/games/([0-9a-f]{12})/(\d+)$') {
            $g = $cache.games[$Matches[1]]; $pi = [int]$Matches[2]
            if (-not $g -or $pi -ge @($g.parts).Count) { Send $stream 404 'text/plain' ([byte[]]@()); return }
            SendFile $stream @($g.parts)[$pi].path $range; return
        }
        if ($path -match '^/saves/(list|get|put)$') {
            $act = $Matches[1]
            $tv = ([string]$query['tv'] -replace '[^A-Za-z0-9 _.()-]', '').Trim()
            if (-not $tv) { $tv = 'TV' }
            $root = Join-Path $cache.gamesDir ('Saves\' + $tv)
            $rel = ([string]$query['p']).Replace('/', '\').TrimStart('\')
            $bad = (-not $rel -and $act -ne 'list') -or $rel -match '(^|\\)\.\.(\\|$)' -or $rel -match ':'
            if ($bad) { Send $stream 404 'text/plain' ([byte[]]@()); return }
            if ($act -eq 'list') {
                $sl = @()
                if (Test-Path -LiteralPath $root) {
                    $sl = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.part' } | ForEach-Object {
                        [ordered]@{ p = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); size = $_.Length; t = [int64]($_.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds } })
                }
                $tvs = @(Get-ChildItem -LiteralPath (Join-Path $cache.gamesDir 'Saves') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                SendJson $stream ([ordered]@{ tv = $tv; folder = $root; tvs = $tvs; items = $sl }); return
            }
            $target = Join-Path $root $rel
            if ($act -eq 'get') { SendFile $stream $target $range; return }
            if ($method -ne 'POST' -or $clen -gt 512MB) { Send $stream 404 'text/plain' ([byte[]]@()); return }
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $target))
            $fs = [IO.File]::Create($target + '.part'); $left = $clen; $buf = New-Object byte[] 65536
            try { while ($left -gt 0) { $n = $stream.Read($buf, 0, [int][Math]::Min(65536, $left)); if ($n -le 0) { break }; $fs.Write($buf, 0, $n); $left -= $n } } finally { $fs.Dispose() }
            if ($left -ne 0) { Remove-Item -LiteralPath ($target + '.part') -Force -ErrorAction SilentlyContinue; SendJson $stream @{ ok = $false }; return }
            Move-Item -LiteralPath ($target + '.part') -Destination $target -Force
            if ($query['t'] -match '^\d+$') { try { (Get-Item -LiteralPath $target).LastWriteTimeUtc = ([datetime]'1970-01-01').AddMilliseconds([double]$query['t']) } catch { } }
            SendJson $stream @{ ok = $true }; return
        }
        # Games added to Sunshine (not Desktop or Steam): TV Home shows them, and Moonlight opens straight into one.
        if ($path -eq '/streamgames') {
            # pc: the name Moonlight knows this PC by (Sunshine's name, else the host name as typed: Moonlight matches case).
            $sl = @(); $sn = [System.Net.Dns]::GetHostName()
            $conf = "$env:ProgramFiles\Sunshine\config\sunshine.conf"
            if ((Test-Path -LiteralPath $conf) -and ((Get-Content -LiteralPath $conf -Raw) -match '(?m)^\s*sunshine_name\s*=\s*(.+?)\s*$')) { $sn = $Matches[1] }
            foreach ($f in @("$env:ProgramFiles\Sunshine\config\apps.json", "$env:ProgramData\Sunshine\apps.json")) {
                if (-not (Test-Path -LiteralPath $f)) { continue }
                try { $sl = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).apps | Where-Object { $_.name -and $_.name -notmatch '^(Desktop|Steam Big Picture)$' } | ForEach-Object { [ordered]@{ name = [string]$_.name } }) } catch { }
                break
            }
            SendJson $stream ([ordered]@{ pc = $sn; items = $sl }); return
        }
        if ($path -eq '/emus') {
            $el = @(@($cache.emus.Values) | ForEach-Object {
                [ordered]@{ id = $_.id; name = $_.name; app = $_.app; installed = [bool]$_.exe; state = [string]$cache.emuState[$_.id]
                    games = @(@($_.games) | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } }) } })
            SendJson $stream ([ordered]@{ folder = $cache.gamesDir; items = $el }); return
        }
        if ($path -match '^/emus/(rpcs3|cemu)/(install|open|launch)$') {
            $eid = $Matches[1]; $act = $Matches[2]; $e = $cache.emus[$eid]
            if ($act -eq 'install') {
                if ([string]$cache.emuState[$eid] -match '^(Finding|Downloading|Unpacking)') { SendJson $stream @{ ok = $true; state = $cache.emuState[$eid] }; return }
                $cache.emuState[$eid] = 'Starting'
                $ips = [PowerShell]::Create()
                [void]$ips.AddScript($cache.installText).AddArgument($cache).AddArgument($eid)
                $cache.emuJobs[$eid] = @{ ps = $ips; h = $ips.BeginInvoke() }
                SendJson $stream @{ ok = $true; state = 'Starting' }; return
            }
            if (-not $e -or -not $e.exe) { SendJson $stream @{ ok = $false; error = 'not installed' }; return }
            $g = $null
            if ($act -eq 'launch' -and $query['game']) { $g = @(@($e.games) | Where-Object { $_.id -eq $query['game'] })[0] }
            $pname = [IO.Path]::GetFileNameWithoutExtension($e.exe)
            if ($g) { Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 600 }
            $ea = @()
            if ($g -and $eid -eq 'rpcs3') { $ea = @('--no-gui', ('"' + $g.path + '"')) }
            if ($g -and $eid -eq 'cemu') { $ea = @('-f', '-g', ('"' + $g.path + '"')) }
            if ($ea.Count) { $pr = Start-Process -FilePath $e.exe -ArgumentList $ea -WorkingDirectory (Split-Path $e.exe) -PassThru }
            else { $pr = Start-Process -FilePath $e.exe -WorkingDirectory (Split-Path $e.exe) -PassThru }
            SendJson $stream @{ ok = $true; game = $(if ($g) { $g.name } else { '' }) }
            # RPCS3 opens its game in a window: Alt+Enter makes it full screen once it's up.
            if ($g -and $eid -eq 'rpcs3') {
                Start-Sleep -Seconds 10
                try { $ws = New-Object -ComObject WScript.Shell; if ($ws.AppActivate([int]$pr.Id)) { Start-Sleep -Milliseconds 300; $ws.SendKeys('%{ENTER}') } } catch { }
            }
            return
        }
        if ($path -eq '/info') { SendJson $stream ([ordered]@{ app = 'TVLink'; version = 12; games = $true; saves = $true; emus = $true; streamgames = $true; mirror = $true; temps = $true; pcwalls = $true; media = $true; cameras = $true; alerts = $true; live = $true; sound = $true; name = $info.name; mac = $info.mac; cpu = $info.cpu; gpu = $info.gpu; wallpaperEngine = [bool]$we.exe }); return }
        if ($path -eq '/current') { $c = Get-Current $we; $c.Remove('path'); SendJson $stream $c; return }
        if ($path -eq '/current/file') {
            $c = Get-Current $we
            if ($c.path) { SendFile $stream $c.path $range } else { Send $stream 404 'text/plain' ([byte[]]@()) }
            return
        }
        if ($path -eq '/cameras/diag') {
            $g = $cache.cams
            SendJson $stream ([ordered]@{ from = [string]$g.from; ports = @($g.ports); rtspPort = $g.port; rtspOk = $g.rtspOk; apiPort = $g.api; apiOk = $g.apiOk; names = @($g.names); relay = [bool]$cache.relayOn; motion = [bool]$cache.motionOn; motionError = [string]$cache.motionError })
            return
        }
        if ($path -match '^/camsnap/(.+)$') {
            # A still picture from a camera (go2rtc makes it), for the Cameras screen.
            $name = $Matches[1]; $g = $cache.cams
            $snap = $null
            $key = 'snap:' + $name
            $old = $cache[$key]
            if ($old -and ((Get-Date) - $old.at).TotalSeconds -lt 2) { $snap = $old.bytes }
            elseif ($g -and $g.apiOk) {
                try {
                    $wc = New-Object Net.WebClient
                    $snap = $wc.DownloadData("http://127.0.0.1:$($g.api)/api/frame.jpeg?src=" + [Uri]::EscapeDataString($name))
                    if ($snap -and $snap.Length -gt 500) { $cache[$key] = @{ at = Get-Date; bytes = $snap } } else { $snap = $null }
                } catch { $snap = $null }
            }
            if ($snap) { Send $stream 200 'image/jpeg' ([byte[]]$snap) } else { Send $stream 404 'text/plain' ([byte[]]@()) }
            return
        }
        if ($path -eq '/camevents') {
            $evs = @($cache.events)
            $sens = [int]$cache.motionSens; if (-not $sens) { $sens = 2 }
            $need = @{ 1 = 9.0; 2 = 5.0; 3 = 2.5 }[$sens]; if (-not $need) { $need = 5.0 }
            SendJson $stream ([ordered]@{ on = [bool]$cache.motionOn; sens = $sens; need = $need; items = @($evs | Select-Object -Last 150 | ForEach-Object { [ordered]@{ id = $_.id; cam = $_.cam; at = $_.at; score = $_.score; sens = $sens; need = $need } }) })
            return
        }
        if ($path -match '^/camevent/([0-9a-f]+)\.jpg$') {
            $id = $Matches[1]; $e = @($cache.events | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            if ($e -and $e.jpg) { Send $stream 200 'image/jpeg' ([byte[]]$e.jpg) } else { Send $stream 404 'text/plain' ([byte[]]@()) }
            return
        }
        if ($path -match '^/camalerts/(on|off)$') {
            $cache.motionOn = ($Matches[1] -eq 'on')
            if ($cache.motionOn) {
                $q = [Uri]$(('http://x' + $parts[1]))
                $sens = 2; if ($q.Query -match 'sens=(\d)') { $sens = [int]$Matches[1] }
                $cache.motionSens = $sens
                $cams = @(); if ($q.Query -match 'cams=([^&]*)') { $cams = @([Uri]::UnescapeDataString($Matches[1]) -split ',' | Where-Object { $_ }) }
                $cache.motionCams = $cams
            }
            SendJson $stream @{ ok = $true; on = [bool]$cache.motionOn }; return
        }
        if ($path -eq '/media/fullscreen') {
            # Before the PC is streamed to the TV (Moonlight): make the playing video full screen,
            # so the TV shows just the video.
            $ok = $false
            try { $win = Find-VideoWindow $cache $null; if ($win) { $ok = Set-VideoFull $cache $win } } catch { }
            SendJson $stream @{ ok = $ok }; return
        }
        if ($path -eq '/cameras') {
            $g = $cache.cams
            $list = @()
            if ($g) {
                $all = @($g.names)
                foreach ($n in $all) {
                    if ($n -match '(_|-)(sub|sd|low|small)$' -and ($all -contains ($n -replace '(_|-)(sub|sd|low|small)$', ''))) { continue }
                    $sub = @($all | Where-Object { $_ -match ('^' + [regex]::Escape($n) + '(_|-)(sub|sd|low|small)$') } | Select-Object -First 1)
                    # Where the camera is (its address, never its login) and which feed this is, so the TV can tell
                    # two feeds of one camera from two cameras.
                    $u = [string]$g.src[$n]; $hostName = ''; $q = ''
                    if ($u -match '^\w+://(?:[^@/]*@)?([^:/?#]+)') { $hostName = $Matches[1] }
                    if ($u -match 'stream2|subtype=1|/sub|_sub|channel=\d+&subtype=1|/102|/h264Preview_\d+_sub') { $q = 'sd' } elseif ($u -match 'stream1|subtype=0|/main|/101|_main') { $q = 'hd' }
                    $list += [ordered]@{ id = $n; name = (($n -replace '[_-]+', ' ').Trim()); path = [Uri]::EscapeDataString($n); sub = $(if ($sub) { [Uri]::EscapeDataString([string]$sub[0]) } else { '' }); host = $hostName; q = $q }
                }
            }
            SendJson $stream ([ordered]@{ port = 8790; snaps = [bool]($g -and $g.apiOk); user = $(if ($g) { $g.user } else { '' }); pass = $(if ($g) { $g.pass } else { '' }); items = $list; from = $(if ($g) { [string]$g.from } else { '' }) })
            return
        }
        if ($path -eq '/media') {
            $m = Get-Media $cache
            $m.video = $false
            try { if ($m.status -eq 'playing' -and (Find-VideoWindow $cache $m)) { $m.video = -not ($cache.liveFail -and ((Get-Date) - $cache.liveFail).TotalSeconds -lt 20) } } catch { }
            SendJson $stream $m; return
        }
        if ($path -eq '/media/live.mjpg') {
            # The playing video, about 12 pictures a second (MJPEG), shown inside the circle on the TV's
            # Music screen. The video is made full screen on the PC first so only the video is sent.
            try {
                Ensure-Cap
                $win = Find-VideoWindow $cache $null
                if (-not $win) { Send $stream 404 'text/plain' ([byte[]]@()); return }
                [void](Set-VideoFull $cache $win)
                $client.SendTimeout = 8000
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: multipart/x-mixed-replace; boundary=tvframe`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $crlf = [Text.Encoding]::ASCII.GetBytes("`r`n")
                $until = (Get-Date).AddMinutes(30); $next = Get-Date; $w = $null; $fails = 0
                while ((Get-Date) -lt $until) {
                    $t0 = [Environment]::TickCount
                    if ((Get-Date) -ge $next) { $w = [TvLinkCap]::Where($win.h); $next = (Get-Date).AddSeconds(3) }
                    $b = $null
                    if ($w -and -not $w[8]) {
                        # Only the part of the window that's on its screen
                        $x = [Math]::Max($w[0], $w[4]); $y = [Math]::Max($w[1], $w[5])
                        $r = [Math]::Min($w[0] + $w[2], $w[4] + $w[6]); $bt = [Math]::Min($w[1] + $w[3], $w[5] + $w[7])
                        try { $b = [TvLinkCap]::Grab($x, $y, $r - $x, $bt - $y, 640) } catch { $b = $null }
                    }
                    if ($b) {
                        $fails = 0
                        $ph = [Text.Encoding]::ASCII.GetBytes("--tvframe`r`nContent-Type: image/jpeg`r`nContent-Length: $($b.Length)`r`n`r`n")
                        $stream.Write($ph, 0, $ph.Length); $stream.Write($b, 0, $b.Length); $stream.Write($crlf, 0, 2); $stream.Flush()
                    } elseif (++$fails -gt 40) { $cache.liveFail = Get-Date; break }   # locked, asleep or minimised
                    $wait = 80 - ([Environment]::TickCount - $t0); if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
                }
            } catch { }
            return
        }
        if ($path -eq '/media/audio.wav') {
            # The PC's sound, live, for the TV's Music screen (plays alongside the video in the circle).
            try {
                Ensure-Audio
                $client.SendTimeout = 10000
                $client.NoDelay = $true
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: audio/wav`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $cache.audioWhy = [TvLinkAudio]::Pump($stream, 240)
            } catch { $cache.audioWhy = $_.Exception.Message }
            return
        }
        if ($path -eq '/diag/cap') {
            $err = ''; $lvl = $null
            try { Ensure-Cap; $lvl = (New-Object TvLinkMeter).Read(); Ensure-Audio; $hb = [TvLinkAudio]::Header(48000); if ($hb.Length -ne 44) { $err = 'wav header ' + $hb.Length } } catch { $err = $_.Exception.Message }
            SendJson $stream ([ordered]@{ ok = (-not $err); error = $err; level = $lvl }); return
        }
        if ($path -eq '/media/level') {
            # How loud the PC is playing, 20 times a second (server-sent events), so the circle on the TV
            # moves with the music.
            try {
                Ensure-Cap
                $meter = New-Object TvLinkMeter
                $client.SendTimeout = 8000
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $until = (Get-Date).AddMinutes(30); $ci = [Globalization.CultureInfo]::InvariantCulture
                while ((Get-Date) -lt $until) {
                    $t0 = [Environment]::TickCount
                    $v = $meter.Read()
                    $line = $(if ($v) { 'data: ' + $v[0].ToString('0.000', $ci) + ' ' + $v[1].ToString('0.000', $ci) + ' ' + $v[2].ToString('0.000', $ci) } else { 'data: -1 0 0' })
                    $bb = [Text.Encoding]::ASCII.GetBytes($line + "`n`n")
                    $stream.Write($bb, 0, $bb.Length); $stream.Flush()
                    $wait = 50 - ([Environment]::TickCount - $t0); if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
                }
            } catch { }
            return
        }
        if ($path -eq '/media/art') {
            $b = $cache.art
            if ($b) { Send $stream 200 'image/jpeg' ([byte[]]$b) } else { Send $stream 404 'text/plain' ([byte[]]@()) }
            return
        }
        if ($path -match '^/media/(toggle|play|pause|next|prev|shuffle)$') {
            $ok = $false
            try {
                $s = Get-MediaSession
                if ($s) {
                    $op = switch ($Matches[1]) { 'toggle' { $s.TryTogglePlayPauseAsync() } 'play' { $s.TryPlayAsync() } 'pause' { $s.TryPauseAsync() } 'next' { $s.TrySkipNextAsync() } 'prev' { $s.TrySkipPreviousAsync() } 'shuffle' { $s.TryChangeShuffleActiveAsync(-not [bool]$s.GetPlaybackInfo().IsShuffleActive) } }
                    $ok = [bool](Wait-WinRt $op ([bool]))
                }
            } catch { }
            SendJson $stream @{ ok = $ok }; return
        }
        if ($path -eq '/stats') {
            # Several TVs ask every couple of seconds: share one reading for 1.5 s (the system queries are slow).
            $st = $cache.stats
            if (-not $st -or ((Get-Date) - $st.at).TotalMilliseconds -gt 1500) { $st = @{ at = Get-Date; v = (Get-Stats $info) }; $cache.stats = $st }
            SendJson $stream $st.v; return
        }
        if ($path -eq '/wallpapers') {
            $list = @($we.items.Values | Sort-Object title | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; type = $_.type } })
            SendJson $stream ([ordered]@{ items = $list }); return
        }
        if ($path -eq '/pcwalls') {
            $list = @($walls.Values | ForEach-Object { [ordered]@{ id = $_.id; title = $_.title; kind = $_.kind; type = $(if ($_.path -match '\.(mp4|webm)$') { 'video' } else { 'image' }) } })
            SendJson $stream ([ordered]@{ items = $list; wallpaperEngine = [bool]$we.exe }); return
        }
        if ($path -match '^/pcwall/([0-9a-f]{12})/thumb$') {
            # A small preview (640 px wide) for the TV's wallpaper tiles, made once and kept in TEMP.
            $w = $walls[$Matches[1]]
            if (-not $w -or $w.path -match '\.(mp4|webm)$') { Send $stream 404 'text/plain' ([byte[]]@()); return }
            $dir = Join-Path $env:TEMP 'tvlink-thumbs'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $t = Join-Path $dir ($w.id + '.jpg')
            if (-not (Test-Path -LiteralPath $t)) {
                try {
                    Add-Type -AssemblyName System.Drawing
                    $src = [System.Drawing.Image]::FromFile($w.path)
                    $tw = 640; $th = [int][math]::Max(1, $src.Height * $tw / $src.Width)
                    $bmp = New-Object System.Drawing.Bitmap $tw, $th
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.DrawImage($src, 0, 0, $tw, $th)
                    $g.Dispose(); $src.Dispose()
                    $bmp.Save($t, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
                } catch { SendFile $stream $w.path; return }
            }
            SendFile $stream $t; return
        }
        if ($path -match '^/pcwall/([0-9a-f]{12})(/apply)?$') {
            $w = $walls[$Matches[1]]
            if (-not $w) { Send $stream 404 'text/plain' ([byte[]]@()); return }
            if ($Matches[2]) {
                # Sets it as the Windows desktop wallpaper too (Settings > Also set on my PC).
                if (-not ('TvLinkWall' -as [type])) {
                    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class TvLinkWall { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SystemParametersInfo(int a, int b, string c, int d); }'
                }
                $ok = [TvLinkWall]::SystemParametersInfo(20, 0, $w.path, 3)
                SendJson $stream @{ ok = [bool]$ok }; return
            }
            SendFile $stream $w.path $range; return
        }
        if ($path -match '^/wp/([^/]+)/(preview|file|apply)$') {
            $w = $we.items[$Matches[1]]
            if (-not $w) { Send $stream 404 'text/plain' ([byte[]]@()); return }
            switch ($Matches[2]) {
                'preview' { SendFile $stream (Join-Path $w.dir $w.preview) }
                'file' { if ($w.type -eq 'video') { SendFile $stream (Join-Path $w.dir $w.file) $range } else { SendFile $stream (Join-Path $w.dir $w.preview) } }
                'apply' {
                    if ($we.exe) {
                        $target = if ($w.type -eq 'video' -and $w.file) { Join-Path $w.dir $w.file } else { Join-Path $w.dir 'project.json' }
                        Start-Process -FilePath $we.exe -ArgumentList @('-control', 'openWallpaper', '-file', "`"$target`"") -WindowStyle Hidden
                    }
                    SendJson $stream @{ ok = [bool]$we.exe }
                }
            }
            return
        }
        Send $stream 404 'text/plain' ([Text.Encoding]::ASCII.GetBytes('TV Link'))
    } catch {
    } finally {
        try { $client.Close() } catch { }
    }
}

$info = Get-PcInfo
$we = Get-WallpaperEngine
# The folder for your own TV wallpapers (they appear first on the TV's Wallpaper › My PC)
try { [void](New-Item -ItemType Directory -Force -Path (Join-Path ([Environment]::GetFolderPath('MyPictures')) 'TV Wallpapers')) } catch { }
$walls = Get-PcWalls
$wallsLoaded = Get-Date
New-GamesFolders
$weLoaded = Get-Date
# Shared between requests (the Music screen's cover picture, the PC's cameras).
$cache = [hashtable]::Synchronized(@{})
$cache.cams = Get-Go2RtcCams
$camsLoaded = Get-Date
$cache.gamesDir = $GamesDir
$cache.emuDir = $EmuDir
$cache.installText = $installText
$cache.emuState = [hashtable]::Synchronized(@{})
$cache.emuJobs = [hashtable]::Synchronized(@{})
$cache.emusDirty = $false
$cache.games = Get-TvGames
$cache.emus = Get-Emus
$emusLoaded = Get-Date
$cache.linkVersion = $LinkVersion
$updateCheck = (Get-Date).AddMinutes(-355)   # first look 5 minutes after starting, then every 6 hours
# Camera relay: TV -> this PC :8790 -> go2rtc's RTSP on this PC (works even if go2rtc only listens on the PC itself).
$relayPool = [RunspaceFactory]::CreateRunspacePool(1, 16)
$relayPool.Open()
$pipeText = {
    param($client, $port)
    $up = $null
    try {
        $client.NoDelay = $true
        $up = New-Object Net.Sockets.TcpClient
        $up.NoDelay = $true
        $up.Connect('127.0.0.1', [int]$port)
        $a = $client.GetStream(); $b = $up.GetStream()
        $t1 = $a.CopyToAsync($b, 65536); $t2 = $b.CopyToAsync($a, 65536)
        [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($t1, $t2))
    } catch { } finally { try { $client.Close() } catch { }; try { if ($up) { $up.Close() } } catch { } }
}.ToString()
$relay = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 8790)
try { $relay.Start(); $cache.relayOn = $true } catch { $relay = $null; $cache.relayOn = $false }
# Movement alerts: every few seconds, a small grey copy of each camera's picture is compared with the
# last one; a big enough change is an event (with a snapshot) that the TVs show. Off until a TV turns it on.
$cache.events = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
$cache.motionOn = $false
$motionText = {
    param($cache)
    Add-Type -AssemblyName System.Drawing
    $prev = @{}; $avg = @{}; $last = @{}
    while ($true) {
        Start-Sleep -Seconds 3
        if (-not $cache.motionOn) { $prev = @{}; continue }
        $g = $cache.cams
        if (-not $g -or -not $g.apiOk) { $cache.motionError = 'No camera pictures from go2rtc'; continue }
        $all = @($g.names)
        foreach ($n in $all) {
            # Watch each camera once: skip lighter duplicate feeds ("cam2", "cam_sub") when the main one exists.
            if ($n -match '^(.*?)[ _-]?(2|sd|sub|low|small)$' -and ($all -contains $Matches[1])) { continue }
            $want = @($cache.motionCams); if ($want.Count -and -not ($want -contains $n)) { continue }
            $feed = $n; $lite = @($all | Where-Object { $_ -match ('^' + [regex]::Escape($n) + '[ _-]?(2|sd|sub|low|small)$') } | Select-Object -First 1); if ($lite) { $feed = [string]$lite[0] }
            try {
                $wc = New-Object Net.WebClient
                $bytes = $wc.DownloadData("http://127.0.0.1:$($g.api)/api/frame.jpeg?src=" + [Uri]::EscapeDataString($feed))
                $ms = New-Object IO.MemoryStream(, $bytes)
                $img = [System.Drawing.Image]::FromStream($ms)
                $bmp = New-Object System.Drawing.Bitmap 48, 27
                $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.DrawImage($img, 0, 0, 48, 27); $gr.Dispose(); $img.Dispose()
                $grey = New-Object int[] (48 * 27)
                for ($y = 0; $y -lt 27; $y++) { for ($x = 0; $x -lt 48; $x++) { $c = $bmp.GetPixel($x, $y); $grey[$y * 48 + $x] = [int](($c.R * 3 + $c.G * 6 + $c.B) / 10) } }
                $bmp.Dispose()
                if ($prev.ContainsKey($n)) {
                    $p = $prev[$n]; $changed = 0
                    for ($i = 0; $i -lt $grey.Length; $i++) { if ([Math]::Abs($grey[$i] - $p[$i]) -gt 28) { $changed++ } }
                    $score = [Math]::Round(100.0 * $changed / $grey.Length, 1)
                    $a = $(if ($avg.ContainsKey($n)) { $avg[$n] } else { $score }); $avg[$n] = $a * 0.9 + $score * 0.1
                    $need = @{ 1 = 9.0; 2 = 5.0; 3 = 2.5 }[[int]$cache.motionSens]; if (-not $need) { $need = 5.0 }
                    $quiet = (-not $last.ContainsKey($n)) -or (((Get-Date) - $last[$n]).TotalSeconds -gt 45)
                    if ($score -ge $need -and $score -ge ($a * 2 + 1) -and $quiet) {
                        $last[$n] = Get-Date
                        $id = ([Guid]::NewGuid().ToString('N')).Substring(0, 12)
                        [void]$cache.events.Add(@{ id = $id; cam = $n; at = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); score = $score; jpg = $bytes })
                        # About a day of alerts for the TV's Alerts screen (each keeps its picture).
                        while ($cache.events.Count -gt 150) { $cache.events.RemoveAt(0) }
                    }
                }
                $prev[$n] = $grey
                $cache.motionError = ''
            } catch { $cache.motionError = $_.Exception.Message }
        }
    }
}.ToString()
$motionPs = [PowerShell]::Create()
[void]$motionPs.AddScript($motionText).AddArgument($cache)
[void]$motionPs.BeginInvoke()


$pool = [RunspaceFactory]::CreateRunspacePool(1, 10)
$pool.Open()
$handlerText = $handler.ToString()

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
try { $listener.Start() } catch {
    # The port is taken. If it's an older TV Link (started from an old folder or an old shortcut),
    # stop it and take over; if it's this version already, leave it running.
    $old = $null
    try { $old = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/info" -TimeoutSec 4 } catch { }
    if ($old -and $old.app -eq 'TVLink' -and [int]$old.version -lt $LinkVersion) {
        Write-Host "Replacing an older TV Link (version $([int]$old.version))."
        $owners = @()
        try { $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique) } catch { }
        foreach ($o in $owners) { if ($o -and $o -ne $PID) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue } }
        $listener = $null
        for ($try = 0; $try -lt 10 -and -not $listener; $try++) {
            Start-Sleep -Seconds 1
            $l2 = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
            try { $l2.Start(); $listener = $l2 } catch { }
        }
        if (-not $listener) { Write-Host "TV Link couldn't start: port $Port is in use."; exit 0 }
    } else {
        Write-Host "TV Link is already running (port $Port in use)."; exit 0
    }
}
Write-Host "TV Link is running on port $Port. Leave this running; TV Home finds it automatically."

$jobs = New-Object System.Collections.ArrayList
while ($true) {
    if (((Get-Date) - $weLoaded).TotalMinutes -gt 10) { $we = Get-WallpaperEngine; $weLoaded = Get-Date }
    # New pictures in TV Wallpapers show up on the TV within a minute.
    if (((Get-Date) - $wallsLoaded).TotalSeconds -gt 60) { $walls = Get-PcWalls; $cache.games = Get-TvGames; $wallsLoaded = Get-Date }
    # PS3 / Wii U emulators and their games: every 5 minutes, and straight after one is installed.
    if ($cache.emusDirty -or ((Get-Date) - $emusLoaded).TotalMinutes -gt 5) { $cache.emusDirty = $false; $cache.emus = Get-Emus; $emusLoaded = Get-Date }
    if (((Get-Date) - $updateCheck).TotalHours -ge 6) {
        $updateCheck = Get-Date
        $ups = [PowerShell]::Create(); [void]$ups.AddScript($selfUpdateText).AddArgument($cache); [void]$jobs.Add([pscustomobject]@{ P = $ups; H = $ups.BeginInvoke() })
    }
    # Look for cameras again every 10 minutes (every minute while none are found, e.g. Afterglow not open yet).
    if (((Get-Date) - $camsLoaded).TotalSeconds -gt $(if (@($cache.cams.names).Count) { 600 } else { 60 })) { $cache.cams = Get-Go2RtcCams; $camsLoaded = Get-Date }
    if ($relay -and $relay.Pending()) {
        $rc = $relay.AcceptTcpClient()
        $rp = [PowerShell]::Create()
        $rp.RunspacePool = $relayPool
        [void]$rp.AddScript($pipeText).AddArgument($rc).AddArgument($cache.cams.port)
        [void]$jobs.Add([pscustomobject]@{ P = $rp; H = $rp.BeginInvoke() })
        continue
    }
    if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 40
        for ($i = $jobs.Count - 1; $i -ge 0; $i--) { if ($jobs[$i].H.IsCompleted) { try { $jobs[$i].P.EndInvoke($jobs[$i].H) } catch { }; $jobs[$i].P.Dispose(); $jobs.RemoveAt($i) } }
        continue
    }
    $client = $listener.AcceptTcpClient()
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($handlerText).AddArgument($client).AddArgument($info).AddArgument($we).AddArgument($walls).AddArgument($cache)
    [void]$jobs.Add([pscustomobject]@{ P = $ps; H = $ps.BeginInvoke() })
}
