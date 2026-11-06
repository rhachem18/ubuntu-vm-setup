<#
.SYNOPSIS
  Guided setup for a clean Ubuntu Desktop VM, on Hyper-V or VirtualBox automatically.

.DESCRIPTION
  A step-by-step wizard anyone can follow. It detects the best hypervisor, shows the
  recommended settings (with your machine's limits), lets you accept or customize them,
  shows a plain summary, then builds.
    - Hyper-V enabled            -> builds on Hyper-V (native speed)
    - hypervisor forced on (VBS) -> warns to enable Hyper-V; VirtualBox would be slow
    - no hypervisor              -> builds on VirtualBox (full speed)
  Shared: latest Ubuntu LTS, verified ISO download, clean snapshot, logging to
  VMs\setup-log-*.txt (VM names, username and password masked).

.NOTES
  RUN (PowerShell as Administrator):
     cd $env:USERPROFILE\Downloads
     Set-ExecutionPolicy -Scope Process Bypass
     Unblock-File .\setup-ubuntu-vm.ps1
     .\setup-ubuntu-vm.ps1
  Override any default up front:  .\setup-ubuntu-vm.ps1 -VMName ubuntu-test -MemoryMB 8192
  Rehearse without changing anything:  .\setup-ubuntu-vm.ps1 -DryRun
     (works without admin, but Hyper-V VMs are only visible to an elevated session)
  If Hyper-V is off but the hypervisor is on (VBS), enable it for speed:
     dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart   (then reboot)
#>

param(
    [string]$VMName        = "ubuntu-dev",
    [string]$UbuntuVersion = "lts",
    [string]$Username      = "dev",
    [int]$MemoryMB         = 8192,
    [int]$Cpus             = 4,
    [int]$DiskGB           = 50,
    [string]$TimeZone      = "Europe/Lisbon",
    [string]$WorkDir       = "$env:USERPROFILE\VMs",
    # Walk the whole wizard but change nothing: no create, delete, convert or download.
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- private log --------------------------------------------------------------
# The run log is written by us, not Start-Transcript, so every line can be redacted first.
# VM names, the login username and the password become labelled placeholders (<vm-1>,
# <user>, <password>): you can see a value was there and follow it through the run, but the
# real value never reaches the file. The console still shows real values (except the password).
$script:LogPath = $null
# Until the save folder is chosen there is no file yet: lines wait here, raw, and are
# redacted when written (by then more secrets are known).
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:Secrets = New-Object System.Collections.ArrayList
$script:VmLabelNo = 0
function Add-Secret([string]$value, [string]$kind) {
    if (-not $value) { return }
    foreach ($s in $script:Secrets) { if ($s.Value -eq $value) { return } }
    $label = switch ($kind) { 'vm' { $script:VmLabelNo++; "<vm-$($script:VmLabelNo)>" } 'user' { '<user>' } default { '<password>' } }
    [void]$script:Secrets.Add([pscustomobject]@{ Value = $value; Label = $label; Kind = $kind })
}
function Redact([string]$text, [switch]$PasswordOnly) {
    if (-not $text) { return $text }
    # Longest first, so 'ubuntu-io-dev' is replaced before a shorter name inside it.
    foreach ($s in ($script:Secrets | Sort-Object { $_.Value.Length } -Descending)) {
        $esc = [regex]::Escape($s.Value)
        if ($s.Kind -eq 'password') { $text = [regex]::Replace($text, $esc, $s.Label) }
        elseif (-not $PasswordOnly) { $text = [regex]::Replace($text, "(?<![A-Za-z0-9._-])$esc(?![A-Za-z0-9_-])", $s.Label, 'IgnoreCase') }
    }
    if (-not $PasswordOnly -and $env:USERPROFILE) { $text = [regex]::Replace($text, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', 'IgnoreCase') }
    return $text
}
function Write-Log([string]$line) {
    if (-not $script:LogPath) { if ($null -ne $script:LogBuffer) { $script:LogBuffer.Add($line) }; return }
    # The file is created with a UTF-8 BOM (so PS 5.1 shows the check marks right); appends add none.
    try { [IO.File]::AppendAllText($script:LogPath, (Redact $line) + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch {}
}
function Start-Log([string]$dir) {
    $path = Join-Path $dir ("setup-log-{0:yyyyMMdd-HHmmss}{1}.txt" -f (Get-Date), $(if ($DryRun) { '-dryrun' } else { '' }))
    [IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF))
    $script:LogPath = $path
    $buf = $script:LogBuffer; $script:LogBuffer = $null
    foreach ($l in $buf) { Write-Log $l }
}
# Everything the wizard prints goes through Write-Host, so wrapping it logs the whole run.
# In-place progress lines (-NoNewline) are console-only.
function Write-Host {
    param([Parameter(Position = 0)]$Object = "", [switch]$NoNewline, $ForegroundColor)
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    if (-not $NoNewline) { Write-Log ("$Object" -replace "^`r", '') }
}
# Read-Host plus a log line with the (redacted) answer. -Secret vm|user registers the answer
# as a secret before it is logged.
function Ask([string]$prompt, [string]$Secret) {
    $a = "$(Read-Host $prompt)"
    if ($Secret -and $a.Trim()) { Add-Secret $a.Trim() $Secret }
    Write-Log "${prompt}: $a"
    return $a
}

# Console width, read live so dividers and redraws fit any window size (prevents text jumping).
function Get-Width { try { $w = $Host.UI.RawUI.WindowSize.Width } catch { $w = 80 }; if (-not $w -or $w -lt 20) { $w = 80 }; return $w }
function Rule { return ("-" * [math]::Min(60, (Get-Width) - 1)) }
$Rule = Rule
$script:StepNo = 0; $script:StepTotal = 6
function Section($msg) { $script:Rule = Rule; Write-Host ""; Write-Host $script:Rule -ForegroundColor Cyan; Write-Host "  $msg" -ForegroundColor Cyan; Write-Host $script:Rule -ForegroundColor Cyan }
function Step($msg) { $script:StepNo++; $script:Rule = Rule; Write-Host ""; Write-Host $script:Rule -ForegroundColor Cyan; Write-Host ("  BUILDING  {0}/{1}   {2}" -f $script:StepNo, $script:StepTotal, $msg) -ForegroundColor Cyan; Write-Host $script:Rule -ForegroundColor Cyan }
function Info($msg) { Write-Host "   - $msg" }
function Warn($msg) { Write-Host "   ! $msg" -ForegroundColor Yellow }
function OK($msg)   { Write-Host "   $([char]0x2713) $msg" -ForegroundColor Green }
function Get-Text($resp) { if ($resp.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($resp.Content) }; return [string]$resp.Content }
function Native([scriptblock]$Cmd) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & $Cmd 2>$null | Out-Null } finally { $ErrorActionPreference = $prev }; return $LASTEXITCODE }
# Like Native, but returns stdout lines. In Windows PowerShell 5.1 even `2>$null` on a native
# command throws under EAP=Stop when it writes to stderr, so read-only queries go through here.
# Check $LASTEXITCODE after calling.
function NativeOut([scriptblock]$Cmd) { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $o = @(& $Cmd 2>$null) } finally { $ErrorActionPreference = $prev }; return $o }
function Would($msg) { Write-Host "   [dry run] would $msg" -ForegroundColor Magenta }
function Get-VBoxManage { foreach ($c in @("$env:VBOX_MSI_INSTALL_PATH\VBoxManage.exe", "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe")) { if ($c -and (Test-Path $c)) { return $c } }; return $null }

function Resolve-UbuntuVersion($req) {
    if ($req -match '^\d+\.\d+$') { return $req }
    $metaUrl = if ($req -eq 'latest') { 'https://changelogs.ubuntu.com/meta-release' } else { 'https://changelogs.ubuntu.com/meta-release-lts' }
    try {
        $text = Get-Text (Invoke-WebRequest $metaUrl -UseBasicParsing -TimeoutSec 20)
        $bestNum = -1; $bestStr = $null
        foreach ($block in ($text -split "`n`n")) {
            if ($block -match 'Supported:\s*1' -and $block -match 'Version:\s*(\d+)\.(\d+)') {
                $num = [int]$Matches[1]*100 + [int]$Matches[2]
                if ($num -gt $bestNum) { $bestNum = $num; $bestStr = "{0}.{1:D2}" -f [int]$Matches[1], [int]$Matches[2] }
            }
        }
        if ($bestStr) { return $bestStr } else { throw "none" }
    } catch { Warn "Could not read release metadata. Falling back to 26.04."; return "26.04" }
}
function Get-Sha256WithProgress([string]$path, [string]$label) {
    $sha = [Security.Cryptography.SHA256]::Create()
    # ReadWrite sharing: the ISO may be attached to a VM at the same time.
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] (4MB); $total = [math]::Max([int64]1, $fs.Length); $done = [int64]0; $last = -1
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $done += $n
            $pct = [int][math]::Floor($done * 100 / $total)
            if ($pct -ne $last) { $last = $pct; $w = (Get-Width) - 1; Write-Host ("`r" + ("  {0,3}%   {1}" -f $pct, $label).PadRight($w)) -NoNewline }
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
    } finally { $fs.Dispose() }
    Microsoft.PowerShell.Utility\Write-Host ""
    return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
}
function Get-UbuntuIso($UbuntuVersion, $WorkDir) {
    $ver = Resolve-UbuntuVersion $UbuntuVersion
    Info "Latest Ubuntu: $ver"
    $base = "https://releases.ubuntu.com/$ver"
    $sumsRaw = Get-Text (Invoke-WebRequest "$base/SHA256SUMS" -UseBasicParsing)
    $isoName = $null; $hash = $null
    foreach ($raw in ($sumsRaw -split "`n")) {
        $t = $raw.Trim(); if (-not $t) { continue }
        $tok = $t -split '\s+', 2; if ($tok.Count -lt 2) { continue }
        $h = $tok[0].Trim(); $f = $tok[1].TrimStart('*').Trim()
        if ($h.Length -eq 64 -and $f -like 'ubuntu-*-desktop-amd64.iso') { $isoName = $f; $hash = $h; break }
    }
    if (-not $isoName) { throw "No desktop ISO found for Ubuntu $ver." }
    Info "ISO: $isoName"
    $isoPath = Join-Path $WorkDir $isoName; $url = "$base/$isoName"
    function Test-IsoHash($p, $hh, $label) { (Test-Path $p) -and ((Get-Sha256WithProgress $p $label) -eq $hh.ToUpper()) }
    $verified = $false
    for ($a = 1; $a -le 2 -and -not $verified; $a++) {
        if (Test-IsoHash $isoPath $hash "checking the saved ISO's checksum") { OK "ISO present and verified, skipping download."; $verified = $true; break }
        if ($a -eq 2) { Warn "Retrying download once..." }
        Info "Downloading $isoName (about 6 GB)"
        try {
            if (Test-Path $isoPath) { Remove-Item $isoPath -Force -ErrorAction SilentlyContinue }
            $job = Start-BitsTransfer -Source $url -Destination $isoPath -Asynchronous -DisplayName "Ubuntu ISO"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $job = Get-BitsTransfer -JobId $job.JobId; $state = "$($job.JobState)"
                if ($state -eq 'Transferred') { break }
                if ($state -in 'Error','Cancelled') { $e = $job.ErrorDescription; Remove-BitsTransfer $job; throw "BITS: $e" }
                if ($state -eq 'Suspended') { Resume-BitsTransfer $job -Asynchronous | Out-Null }
                $tot = [double]$job.BytesTotal; $done = [double]$job.BytesTransferred
                if ($tot -gt 0 -and $tot -lt [uint64]::MaxValue) {
                    $pct = [math]::Round($done*100/$tot,1)
                    $spd = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($done/1MB/$sw.Elapsed.TotalSeconds,1) } else { 0 }
                    $eta = if ($spd -gt 0) { [math]::Round(($tot-$done)/1MB/$spd/60,1) } else { "?" }
                    $w = (Get-Width) - 1; $ln = ("  {0,5}%   {1:N0} / {2:N0} MB   {3} MB/s   ~{4} min left" -f $pct,($done/1MB),($tot/1MB),$spd,$eta)
                    if ($ln.Length -gt $w) { $ln = $ln.Substring(0, $w) }
                    Write-Host ("`r" + $ln.PadRight($w)) -NoNewline
                }
                Start-Sleep -Seconds 1
            }
            Complete-BitsTransfer $job
            Write-Host ("`r" + ("  100%   download complete: {0:N0} MB in {1:mm\:ss}" -f ($job.BytesTotal/1MB), $sw.Elapsed)).PadRight((Get-Width) - 1)
        } catch {
            Write-Host "`nBITS unavailable ($($_.Exception.Message)). Trying curl..." -ForegroundColor Yellow
            & curl.exe -L --fail -o $isoPath $url
            if ($LASTEXITCODE -ne 0) { Warn "curl failed."; continue }
        }
        if (Test-IsoHash $isoPath $hash "verifying the download's checksum") { OK "Checksum OK."; $verified = $true } else { Warn "Checksum mismatch."; Remove-Item $isoPath -Force -ErrorAction SilentlyContinue }
    }
    if (-not $verified) { throw "Could not obtain a valid ISO after 2 attempts." }
    return [pscustomobject]@{ Path = $isoPath; Name = $isoName; Version = $ver }
}

function Get-Sha512Crypt([string]$password, [string]$salt) {
    # The standard Linux password hash ("$6$salt$..." = SHA-512 crypt, 5000 rounds, Drepper's
    # spec), so the install settings never carry the password itself. Checked against
    # `openssl passwd -6`. PowerShell variables ignore case, hence the distinct names.
    $itoa = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    if (-not $salt) {
        $rnd = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
        $salt = -join ($rnd | ForEach-Object { $itoa[$_ % 64] })
    }
    $sha = [Security.Cryptography.SHA512]::Create()
    $pw = [Text.Encoding]::UTF8.GetBytes($password); $sl = [Text.Encoding]::ASCII.GetBytes($salt); $plen = $pw.Length
    $buf = New-Object System.Collections.Generic.List[byte]
    $buf.AddRange($pw); $buf.AddRange($sl); $buf.AddRange($pw)
    $hB = $sha.ComputeHash($buf.ToArray())
    $buf.Clear(); $buf.AddRange($pw); $buf.AddRange($sl)
    for ($n = $plen; $n -gt 64; $n -= 64) { $buf.AddRange($hB) }
    if ($n -gt 0) { $buf.AddRange([byte[]]$hB[0..($n - 1)]) }
    for ($n = $plen; $n -gt 0; $n = $n -shr 1) { if ($n -band 1) { $buf.AddRange($hB) } else { $buf.AddRange($pw) } }
    $hA = $sha.ComputeHash($buf.ToArray())
    $buf.Clear(); for ($i = 0; $i -lt $plen; $i++) { $buf.AddRange($pw) }
    $hDP = $sha.ComputeHash($buf.ToArray())
    $pSeq = New-Object byte[] $plen; for ($i = 0; $i -lt $plen; $i++) { $pSeq[$i] = $hDP[$i % 64] }
    $buf.Clear(); for ($i = 0; $i -lt 16 + $hA[0]; $i++) { $buf.AddRange($sl) }
    $hDS = $sha.ComputeHash($buf.ToArray())
    $sSeq = New-Object byte[] $sl.Length; for ($i = 0; $i -lt $sl.Length; $i++) { $sSeq[$i] = $hDS[$i % 64] }
    $cur = $hA
    for ($i = 0; $i -lt 5000; $i++) {
        $buf.Clear()
        if ($i -band 1) { $buf.AddRange($pSeq) } else { $buf.AddRange($cur) }
        if ($i % 3) { $buf.AddRange($sSeq) }
        if ($i % 7) { $buf.AddRange($pSeq) }
        if ($i -band 1) { $buf.AddRange($cur) } else { $buf.AddRange($pSeq) }
        $cur = $sha.ComputeHash($buf.ToArray())
    }
    $out = New-Object Text.StringBuilder
    $order = @(0,21,42, 22,43,1, 44,2,23, 3,24,45, 25,46,4, 47,5,26, 6,27,48, 28,49,7, 50,8,29, 9,30,51, 31,52,10, 53,11,32, 12,33,54, 34,55,13, 56,14,35, 15,36,57, 37,58,16, 59,17,38, 18,39,60, 40,61,19, 62,20,41)
    for ($g = 0; $g -lt $order.Count; $g += 3) {
        $w = ([int]$cur[$order[$g]] -shl 16) -bor ([int]$cur[$order[$g + 1]] -shl 8) -bor [int]$cur[$order[$g + 2]]
        for ($k = 0; $k -lt 4; $k++) { [void]$out.Append($itoa[$w -band 63]); $w = $w -shr 6 }
    }
    $w = [int]$cur[63]; for ($k = 0; $k -lt 2; $k++) { [void]$out.Append($itoa[$w -band 63]); $w = $w -shr 6 }
    return "`$6`$$salt`$$($out.ToString())"
}
function Get-HostResolution {
    # The monitor's real pixel size, so the VM's screen fills it in full screen.
    try {
        $v = Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($v) { return @([int]$v.CurrentHorizontalResolution, [int]$v.CurrentVerticalResolution) }
    } catch {}
    return @(1920, 1080)
}

# ---- wizard helpers -------------------------------------------------------
function Prompt-VMName($default) {
    do {
        $in = Ask "VM name (press Enter to use: $default)" -Secret vm
        if ($in) { $default = $in.Trim() }
        $ok = $default -match '^[A-Za-z0-9._-]+$' -and $default -notmatch '^\.+$'
        if (-not $ok) { Warn "Letters, digits, dot, dash or underscore only (not just dots)." }
    } until ($ok)
    return $default
}
function Prompt-WorkDir($default) {
    # Where VMs, the Ubuntu ISO and the logs are saved. Local fixed drives only: Hyper-V
    # doesn't work well from network shares, and a USB drive can disappear mid-build.
    $defIso = @(Get-ChildItem (Join-Path $default "ubuntu-*-desktop-amd64.iso") -ErrorAction SilentlyContinue).Count -gt 0
    $free = try { Format-Size ([IO.DriveInfo](Split-Path -Qualifier $default)).AvailableFreeSpace } catch { '?' }
    Info ("Recommended: {0}  ({1} free{2})" -f $default, $free, $(if ($defIso) { '; the Ubuntu ISO is already saved here' } else { '' }))
    while ($true) {
        $in = (Ask "Folder (press Enter to use: $default)").Trim().Trim('"')
        if (-not $in) { $in = $default }
        $in = [Environment]::ExpandEnvironmentVariables($in)
        if ($in -notmatch '^[A-Za-z]:\\') { Warn "Give a full path on a local drive, like D:\VMs."; continue }
        try { $full = [IO.Path]::GetFullPath($in).TrimEnd('\') } catch { Warn "That isn't a valid folder path."; continue }
        $drive = try { [IO.DriveInfo]$full.Substring(0, 2) } catch { $null }
        if (-not $drive -or -not $drive.IsReady) { Warn "Drive $($full.Substring(0, 2)) isn't available."; continue }
        if ("$($drive.DriveType)" -ne 'Fixed') { Warn "$($full.Substring(0, 2)) is a $($drive.DriveType) drive. Pick a folder on a local fixed drive."; continue }
        if ($full.Length -le 2) { $full = "$full\VMs"; Info "Using $full, so VM folders don't spread over the drive root." }
        if (Test-Path -LiteralPath $full -PathType Leaf) { Warn "$full is a file, not a folder."; continue }
        if ($defIso -and $full -ne $default.TrimEnd('\') -and -not (Get-ChildItem (Join-Path $full "ubuntu-*-desktop-amd64.iso") -ErrorAction SilentlyContinue)) {
            Warn "The Ubuntu ISO isn't in that folder, so it will be downloaded again (about 6 GB)."
        }
        return $full
    }
}
function Prompt-Account($defaultUser) {
    do {
        $in = Ask "Login username (press Enter to use: $defaultUser)" -Secret user
        if ($in) { $defaultUser = $in.Trim() }
        $ok = $defaultUser -match '^[a-z][a-z0-9_-]*$'
        if (-not $ok) { Warn "Lowercase, start with a letter." }
    } until ($ok)
    do {
        $p1 = Read-Host "Choose a password" -AsSecureString
        $p2 = Read-Host "Confirm password" -AsSecureString
        Write-Log "Choose a password: <hidden>"; Write-Log "Confirm password: <hidden>"
        $pw1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $pw2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        $bad = ':"''`\'.ToCharArray()
        $hasBad = ($pw1.IndexOfAny($bad) -ge 0) -or ($pw1 -match "[\r\n]")
        $ok = ($pw1 -eq $pw2) -and ($pw1.Length -ge 4) -and (-not $hasBad)
        # Only the accepted password is registered: it is masked anywhere it appears, from now on,
        # in the log and in VirtualBox's console output (which echoes it).
        if ($ok) { Add-Secret $pw1 'password' }
        if (-not $ok) { Warn "Passwords must match, be 4+ chars, and avoid : `" ' `` \ and newlines." }
    } until ($ok)
    return [pscustomobject]@{ User = $defaultUser; Password = $pw1 }
}
function Format-Size([double]$bytes) { if ($bytes -gt 0 -and $bytes -lt 1MB) { "< 1 MB" } elseif ($bytes -lt 1GB) { "{0:N0} MB" -f ($bytes/1MB) } else { "{0:N1} GB" -f ($bytes/1GB) } }
function Get-NameConflict($name) {
    # Everything this name already points at, on BOTH hypervisors. They share the folder
    # VMs\<name>, so a same-named VM on the other hypervisor is the dangerous case.
    $c = [ordered]@{ HvVM = $false; HvDir = $null; HvReadable = $true; VbVM = $false; VbDir = $null; Folder = $null; FolderBytes = 0 }
    if ($hasHyperVCmdlets) {
        # Get-VM needs admin. Read the whole list so "can't read" isn't mistaken for "not found".
        try {
            $vm = @(Get-VM -ErrorAction Stop) | Where-Object Name -eq $name | Select-Object -First 1
            if ($vm) {
                $c.HvVM = $true
                $d = $vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Select-Object -First 1
                $c.HvDir = if ($d) { Split-Path $d.Path -Parent } else { "$($vm.Path)" }
            }
        } catch { $c.HvReadable = $false }
    }
    if ($vbManage) {
        $names = @((NativeOut { & $vbManage list vms }) | ForEach-Object { if ($_ -match '^"([^"]+)"') { $Matches[1] } })
        if ($names -contains $name) {
            $c.VbVM = $true
            foreach ($l in (NativeOut { & $vbManage showvminfo $name --machinereadable })) { if ($l -match '^CfgFile="(.+)"$') { $c.VbDir = Split-Path ($Matches[1] -replace '\\\\', '\') -Parent } }
        }
    }
    $dir = Join-Path $WorkDir $name
    if (Test-Path -LiteralPath $dir) {
        $c.Folder = $dir
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $c.FolderBytes += $f.Length }
    }
    $c.Any = $c.HvVM -or $c.VbVM -or [bool]$c.Folder
    return [pscustomobject]$c
}
function Show-NameConflict($name, $c) {
    Warn "The name '$name' is already in use. Replacing it deletes:"
    if ($c.HvVM) {
        Write-Host "     - the Hyper-V VM '$name' (turned off and removed)" -ForegroundColor Yellow
        $inFolder = $c.Folder -and $c.HvDir -and ("$($c.HvDir)\").StartsWith("$($c.Folder)\", [StringComparison]::OrdinalIgnoreCase)
        if ($c.HvDir -and -not $inFolder) { Write-Host "       (its disk files in $($c.HvDir) are left in place)" -ForegroundColor Yellow }
    }
    if ($c.VbVM) { Write-Host "     - the VirtualBox VM '$name' and its disks (in $($c.VbDir))" -ForegroundColor Yellow }
    if ($c.Folder) { Write-Host ("     - the folder {0} and everything in it ({1}){2}" -f $c.Folder, (Format-Size $c.FolderBytes), $(if (-not $c.HvVM -and -not $c.VbVM) { '; no VM uses it' } else { '' })) -ForegroundColor Yellow }
}
function Show-SettingsTable($label, $mem, $cpu, $disk, $hostRam, $hostCpu) {
    Write-Host "   $label"
    Write-Host ("     Memory (RAM)   {0,5} MB   of your {1} MB" -f $mem, $hostRam)
    Write-Host ("     Processors     {0,5} CPUs of your {1}" -f $cpu, $hostCpu)
    if ($disk) { Write-Host ("     Disk size      {0,5} GB   (grows as needed)" -f $disk) }
    else       { Write-Host  "     Disk size         default (grows as needed)" }
}
function Read-IntOr($prompt, $default, $min, $max) {
    while ($true) {
        $in = (Ask ("$prompt (press Enter to use: $default)")).Trim()
        if (-not $in) { return $default }
        if ($in -match '^\d+$') {
            $v = [int]$in
            if ($v -lt $min) { Warn "Minimum is $min. Using $min."; return $min }
            if ($v -gt $max) { Warn "Maximum here is $max. Using $max."; return $max }
            return $v
        }
        Warn "Enter a whole number."
    }
}
function Choose-Settings($hostRam, $hostCpu, $defMem, $defCpu, $defDisk, $defVer) {
    $recMem  = [math]::Min($defMem, [math]::Max(2048, $hostRam - 4096))
    $recCpu  = [math]::Min($defCpu, [math]::Max(1, $hostCpu - 1))
    Write-Host ""
    Show-SettingsTable "Recommended settings:" $recMem $recCpu $defDisk $hostRam $hostCpu
    Write-Host ("     Ubuntu version    latest LTS")
    Write-Host ""
    Write-Host "   How do you want to set it up?"
    Write-Host "     [r] Use the recommended settings (default)"
    Write-Host "     [c] Customize each setting"
    $pick = (Ask "Choice (r/c)").Trim().ToLower()
    if (-not $pick) { $pick = 'r' }

    if ($pick -eq 'c') {
        $maxMem = [math]::Max(2048, $hostRam - 2048)
        $maxCpu = [math]::Max(1, $hostCpu - 1)
        $mem = Read-IntOr "Memory in MB, 1024 = 1 GB" $recMem 2048 $maxMem
        $cpu = Read-IntOr "Number of CPUs" $recCpu 1 $maxCpu
        $disk = Read-IntOr "Disk size in GB" $defDisk 25 4096
        $verIn = (Ask "Ubuntu version: lts, latest or a number like 24.04 (press Enter to use: $defVer)").Trim()
        if (-not $verIn) { $verIn = $defVer }
        return [pscustomobject]@{ Mem = $mem; Cpu = $cpu; Disk = $disk; Ver = $verIn }
    }
    return [pscustomobject]@{ Mem = $recMem; Cpu = $recCpu; Disk = $defDisk; Ver = $defVer }
}
function Show-Summary($osText, $target, $saveDir, $mem, $hostRam, $cpu, $hostCpu, $disk, $user, $name, $c) {
    Write-Host ""
    Write-Host $Rule -ForegroundColor Green
    Write-Host "  READY TO BUILD" -ForegroundColor Green
    Write-Host $Rule -ForegroundColor Green
    # Same order as the questions were asked: where it runs and is saved, name, resources, version, login.
    Write-Host ("  Runs on             {0}" -f $target)
    Write-Host ("  Saved in            {0}" -f $saveDir)
    Write-Host ("  VM name             {0}" -f $name)
    if ($c.HvVM)   { Write-Host ("  DELETES             the Hyper-V VM '{0}'" -f $name) -ForegroundColor Yellow }
    if ($c.VbVM)   { Write-Host ("  DELETES             the VirtualBox VM '{0}' and its disks" -f $name) -ForegroundColor Yellow }
    if ($c.Folder) { Write-Host ("  DELETES             the folder {0}" -f $c.Folder) -ForegroundColor Yellow }
    Write-Host ("  Memory (RAM)        {0} GB     of your {1} GB" -f [math]::Round($mem/1024,1), [math]::Round($hostRam/1024,1))
    Write-Host ("  Processors          {0} CPUs    of your {1}" -f $cpu, $hostCpu)
    Write-Host ("  Disk size           {0} GB    (grows as needed)" -f $disk)
    Write-Host ("  Operating system    {0}" -f $osText)
    Write-Host ("  Login username      {0}" -f $user)
    Write-Host ""
    Write-Host "  Installing takes about 20 minutes, plus the 6 GB download the first time."
    if ($hvEnabled) { Write-Host "  You may need to click Install once in the VM window; the script will tell you." }
    Write-Host $Rule -ForegroundColor Green
}
function Show-BuildPlan($hvEnabled, $name, $WorkDir, $c, $mem, $cpu, $disk, $ver, $isos) {
    # DryRun stand-in for the build: mirrors the real build order, changes nothing.
    Write-Host ""
    Write-Host "   DRY RUN: the build would do the following" -ForegroundColor Magenta
    $vmDir = Join-Path $WorkDir $name
    # The old VM goes only after the ISO is ready, as in the real build.
    $removeOld = {
        if ($c.HvVM)   { Would "turn off and remove the Hyper-V VM '$name'" }
        if ($c.VbVM)   { Would "power off and unregister the VirtualBox VM '$name', deleting its disks" }
        if ($c.Folder) { Would ("delete the folder {0} ({1})" -f $c.Folder, (Format-Size $c.FolderBytes)) }
    }
    # Resolving the version is a read-only metadata lookup, and exercises the same parsing as a real run.
    $ver = Resolve-UbuntuVersion $ver
    $isoLine = if ($isos | Where-Object Name -like "ubuntu-$ver-desktop-*") { "reuse the saved Ubuntu $ver Desktop ISO if its SHA256 still matches (else re-download ~6 GB)" } else { "download the Ubuntu $ver Desktop ISO (~6 GB) into $WorkDir and verify its SHA256" }
    if ($hvEnabled) {
        $hasDefault = $false; try { $hasDefault = [bool](Get-VMSwitch -Name "Default Switch" -ErrorAction Stop) } catch {}
        $sw = if ($hasDefault) { "use the 'Default Switch'" } else { "use the 'Default Switch', or create 'ubuntu-ext-switch' if it's missing" }
        Would $sw
        Would $isoLine
        & $removeOld
        Would "create the folder $vmDir"
        Would "write a cloud-init seed (user-data, meta-data) to $vmDir\seed.vhdx (FAT32, label CIDATA)"
        $res = Get-HostResolution
        Would "create the Gen2 Hyper-V VM '$name': $mem MB RAM, $cpu CPUs, $disk GB disk at $vmDir\$name.vhdx, Secure Boot UEFI CA"
        Would "turn off automatic checkpoints and set its screen to $($res[0])x$($res[1]) (your monitor)"
        Would "boot the installer (you may click Install once), wait for power-off (90 min from when it starts writing), detach ISO + seed, take a 'clean' checkpoint, start the VM"
    } else {
        Would "install or update VirtualBox via winget if needed"
        Would $isoLine
        & $removeOld
        Would "register the VirtualBox VM '$name': $mem MB RAM, $cpu CPUs, EFI, NAT, $disk GB disk at $vmDir\$name.vdi"
        Would "run the unattended install, wait up to 90 min, eject the ISO, take a 'clean' snapshot, start the VM"
    }
}
function Remove-NamedVM($name, $WorkDir, $vbManage) {
    # Remove a VM of this name wherever it lives (Hyper-V and/or VirtualBox), then its folder.
    # This is what makes "replace" safe even when the clashing VM is on the other hypervisor
    # and shares the VMs\<name> folder.
    # An empty or dots-only name would make Join-Path point at WorkDir or above it.
    if (-not $name -or $name -notmatch '^[A-Za-z0-9._-]+$' -or $name -match '^\.+$') { throw "Refusing to delete: '$name' is not a valid VM name." }
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
            Stop-VM $name -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM $name -Force -ErrorAction SilentlyContinue
            Info "Removed Hyper-V VM '$name'."
        }
    }
    if ($vbManage) {
        $vms = NativeOut { & $vbManage list vms }
        if ($vms -match ('"' + [regex]::Escape($name) + '"')) {
            Native { & $vbManage controlvm $name poweroff } | Out-Null
            Start-Sleep -Seconds 2
            Native { & $vbManage unregistervm $name --delete } | Out-Null
            Info "Removed VirtualBox VM '$name'."
        }
    }
    $dir = Join-Path $WorkDir $name
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}
function Remove-Conflict($name, $c) {
    # Replace: remove what the name pointed at, on whichever hypervisor. Runs after the ISO
    # is downloaded and verified, so a failed download never costs you the old VM.
    if (-not $c.Any) { return }
    Step "Removing the old '$name'"
    if ($vbManage) { Native { & $vbManage closemedium disk (Join-Path $WorkDir "$name\$name.vdi") --delete } | Out-Null }
    Remove-NamedVM $name $WorkDir $vbManage
    if (Test-Path -LiteralPath (Join-Path $WorkDir $name)) { throw "Couldn't fully delete $(Join-Path $WorkDir $name) (a file may be in use). Close any VM window and rerun." }
    OK "Removed."
}
function Ensure-Switch {
    $sw = "Default Switch"
    if (Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue) { return $sw }
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw "No active network adapter found to attach a switch to." }
    $sw = "ubuntu-ext-switch"
    if (-not (Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue)) { New-VMSwitch -Name $sw -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null }
    return $sw
}
# ---- install progress (host-side signals only: we can't see inside the installer) ----------
function Try-Step([string]$what, [scriptblock]$do) {
    try { $null = & $do; return $true } catch { Warn "Couldn't $what ($($_.Exception.Message))."; return $false }
}
function Show-VMWindow([string]$name, [string]$kind) {
    # Bring the VM's window to the front, or open it only if none is open. Windows may refuse to
    # raise a window, and opening a second Hyper-V one asks "another user is connected", so an
    # already-open window counts as shown even when it couldn't be raised.
    $title = if ($kind -eq 'hv') { "$name on *" } else { "$name `[*" }
    $open = @(Get-Process -Name $(if ($kind -eq 'hv') { 'vmconnect' } else { 'VirtualBoxVM', 'VirtualBox' }) -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like $title })
    if ($open) {
        try { [void](New-Object -ComObject WScript.Shell).AppActivate($open[0].Id) } catch {}
        return $true
    }
    if ($kind -eq 'hv') { try { Start-Process vmconnect.exe -ArgumentList 'localhost', $name; return $true } catch {} }
    return $false
}
function New-InstallProgress([string]$name, [string]$kind) {
    @{ Name = $name; Kind = $kind; Start = Get-Date; FirstWrite = $null; LastBytes = [int64]0; LastGrowth = Get-Date; Phase = $null; LastLog = Get-Date; LastNudge = Get-Date; OnLine = $false }
}
function Test-InstallTime($t) {
    # Keep waiting? The 90 minutes start when the install starts writing, so time spent waiting
    # for you on the installer's screen doesn't count. 4 hours in all is the hard stop.
    $now = Get-Date
    if ($now -ge $t.Start.AddHours(4)) { return $false }
    return (-not $t.FirstWrite) -or ($now -lt $t.FirstWrite.AddMinutes(90))
}
function Update-InstallProgress($t, $cpu, [int64]$bytes) {
    # Rules: almost nothing written 4+ minutes in means the installer is waiting for you (an
    # automated install starts writing within a couple of minutes); a disk that stopped growing
    # for 10+ minutes with the CPU idle means a stall (the last part of the install writes little,
    # so 5 minutes gave false alarms). Both bring the VM window up, and repeat
    # the reminder every 10 minutes while it lasts.
    $now = Get-Date; $el = $now - $t.Start
    if ($bytes -gt $t.LastBytes + 16MB) { $t.LastBytes = $bytes; $t.LastGrowth = $now }
    if (-not $t.FirstWrite -and $bytes -ge 512MB) { $t.FirstWrite = $now }
    $idleMin = [int][math]::Floor(($now - $t.LastGrowth).TotalMinutes)
    $low = ($null -eq $cpu) -or ($cpu -lt 10)
    $phase = if ($bytes -lt 512MB) { if ($el.TotalMinutes -ge 4) { 'waiting' } else { 'starting' } }
             elseif ($idleMin -ge 10 -and $low) { 'idle' } else { 'installing' }
    $cpuTxt = if ($null -ne $cpu) { "CPU {0,3}%   " -f $cpu } else { '' }
    $status = "{0:hh\:mm\:ss}   {1}{2} written" -f $el, $cpuTxt, (Format-Size $bytes)
    $changed = $phase -ne $t.Phase
    $nudge = -not $changed -and $phase -in 'waiting', 'idle' -and ($now - $t.LastNudge).TotalMinutes -ge 10
    if ($changed -or $nudge) {
        if ($t.OnLine) { Microsoft.PowerShell.Utility\Write-Host ""; $t.OnLine = $false }
        $mins = [int][math]::Floor($el.TotalMinutes)
        switch ($phase) {
            'starting'   { Info "Starting the installer..." }
            'installing' { Info "Installing: Ubuntu is being written to the disk ($(Format-Size $bytes) so far)." }
            'waiting'    {
                Warn "The automatic install hasn't started after $mins minutes. It needs you in the VM window:"
                Write-Host "       - 'Ready to install' / 'Review your choices': click Install." -ForegroundColor Yellow
                Write-Host "       - Asked whether to start the automated install: choose yes." -ForegroundColor Yellow
                Write-Host "       - Anything else: tell whoever is helping you what the window shows." -ForegroundColor Yellow
            }
            'idle'       { Warn "No disk activity for $idleMin minutes. Look at the VM window: it may be waiting for you, or just finishing up." }
        }
        if ($phase -in 'waiting', 'idle') {
            if (Show-VMWindow $t.Name $t.Kind) { Info "The VM window is open for you now." } else { Info "Open the VM window yourself (Hyper-V Manager or VirtualBox, double-click '$($t.Name)')." }
            $t.LastNudge = $now
        }
        $t.Phase = $phase; $t.LastLog = $now
        Write-Log "   [$status]"
    } elseif (($now - $t.LastLog).TotalMinutes -ge 5) { Write-Log "   [$status]  $phase"; $t.LastLog = $now }
    $w = (Get-Width) - 1; $ln = "  $status   $phase"
    if ($ln.Length -gt $w) { $ln = $ln.Substring(0, $w) }
    Write-Host ("`r" + $ln.PadRight($w)) -NoNewline; $t.OnLine = $true
}
# ---- health check of the VM just built (read-only: it reports and suggests, never changes) ----
function Problem([string]$msg, [string[]]$fix) {
    $script:HealthProblems++
    Warn $msg
    if ($fix) { Write-Host "       Fix:  $($fix[0])"; foreach ($f in ($fix | Select-Object -Skip 1)) { Write-Host "             $f" } }
}
function Get-VhdChainBytes([string]$path) {
    # A disk with checkpoints is a chain of .avhdx files on top of the .vhdx: add them all up.
    # Get-VHD reads the real size; a directory listing can lag behind for a file in use.
    $sum = 0; $n = 0
    while ($path -and $n -lt 32) { try { $v = Get-VHD -Path $path -ErrorAction Stop } catch { break }; $sum += $v.FileSize; $path = $v.ParentPath; $n++ }
    return $sum
}
function Test-HvBuild([string]$name, [string]$vmDir) {
    $script:HealthProblems = 0
    Section "Health check"
    try { $vm = Get-VM -Name $name -ErrorAction Stop } catch { Problem "Can't read the Hyper-V VM '$name' ($($_.Exception.Message))."; return $script:HealthProblems }
    $q = "'$name'"
    if ("$($vm.State)" -eq 'Running') { OK "It is running." }
    else { Problem "It isn't running (state: $($vm.State))." @("Start-VM -Name $q") }

    $disks = @($vm | Get-VMHardDiskDrive)
    $seed = @($disks | Where-Object { $_.Path -like '*\seed.vhdx' -or $_.Path -like '*\seed_*.avhdx' })
    $os = $disks | Where-Object { $seed -notcontains $_ } | Select-Object -First 1
    if ($os) {
        $used = Get-VhdChainBytes $os.Path
        if ($used -ge 3GB) { OK ("Ubuntu is on its disk ({0} used)." -f (Format-Size $used)) }
        else { Problem ("Its disk is almost empty ({0} used), so Ubuntu may not have installed." -f (Format-Size $used)) @("Open the VM window and look. If the installer is showing, finish it; otherwise build it again.") }
    } else { Problem "It has no system disk attached." }

    if (@($vm | Get-VMDvdDrive | Where-Object Path).Count) { Problem "The install ISO is still attached." @("Get-VMDvdDrive -VMName $q | Remove-VMDvdDrive") }
    else { OK "The install ISO is detached." }
    if ($seed) { Problem "The install seed disk is still attached. It holds your install settings, including the password hash." @("Get-VMHardDiskDrive -VMName $q | Where-Object Path -like '*\seed*' | Remove-VMHardDiskDrive") }
    else { OK "The install seed disk is detached." }

    $snaps = @($vm | Get-VMSnapshot -ErrorAction SilentlyContinue)
    $clean = @($snaps | Where-Object Name -eq 'clean')
    $other = @($snaps | Where-Object Name -ne 'clean')
    if ($seed -or $other) {
        # The seed disk lives on inside any checkpoint taken while it was attached, so start the
        # checkpoints over once it is detached.
        $why = if ($seed) { "The checkpoints were taken with the seed disk attached." } else { "There are $($other.Count) checkpoint(s) besides 'clean' (Windows adds one automatically each time the VM starts)." }
        Problem $why @("Get-VMSnapshot -VMName $q | Remove-VMSnapshot", "Set-VM -Name $q -AutomaticCheckpointsEnabled `$false", "Stop-VM -Name $q   (shut down inside Ubuntu first if you are logged in)", "Checkpoint-VM -Name $q -SnapshotName clean; Start-VM -Name $q")
    } elseif ($clean.Count -gt 1) {
        Problem "It has $($clean.Count) checkpoints named 'clean', so a reset could pick the wrong one. Keep the oldest." @("Get-VMSnapshot -VMName $q -Name clean | Sort-Object CreationTime | Select-Object -Skip 1 | Remove-VMSnapshot")
    } elseif ($clean) { OK "It has a 'clean' checkpoint to reset to." }
    else { Problem "It has no 'clean' checkpoint to reset to." @("Stop-VM -Name $q", "Checkpoint-VM -Name $q -SnapshotName clean; Start-VM -Name $q") }
    if (-not $seed -and -not $other -and $vm.AutomaticCheckpointsEnabled) { Problem "Automatic checkpoints are on, so Windows adds a checkpoint every time the VM starts." @("Set-VM -Name $q -AutomaticCheckpointsEnabled `$false") }

    $left = @(Get-ChildItem -LiteralPath $vmDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'seed*' -or $_.Name -in 'user-data', 'meta-data' })
    if ($left) { Problem "Install files with your settings are still in $vmDir ($(($left.Name) -join ', '))." @("After the steps above: Remove-Item '$vmDir\seed*', '$vmDir\user-data', '$vmDir\meta-data' -ErrorAction SilentlyContinue") }
    else { OK "No install files are left in its folder." }

    $nic = @($vm | Get-VMNetworkAdapter)
    if (-not $nic) { Problem "It has no network adapter." @("Add-VMNetworkAdapter -VMName $q -SwitchName 'Default Switch'") }
    elseif (-not ($nic | Where-Object SwitchName)) { Problem "Its network adapter isn't connected to a switch, so it has no internet." @("Connect-VMNetworkAdapter -VMName $q -SwitchName 'Default Switch'") }
    else { OK "Its network is connected (switch '$(($nic | Where-Object SwitchName | Select-Object -First 1).SwitchName)')." }
    return $script:HealthProblems
}
function Test-VbBuild([string]$name, [string]$vbm) {
    $script:HealthProblems = 0
    Section "Health check"
    $info = NativeOut { & $vbm showvminfo $name --machinereadable }
    if ($LASTEXITCODE -ne 0 -or -not $info) { Problem "Can't read the VirtualBox VM '$name'."; return $script:HealthProblems }
    $state = ''; $cfg = $null; $disk = $null; $media = @(); $nic = $null
    foreach ($l in $info) {
        if ($l -match '^VMState="([^"]+)"') { $state = $Matches[1] }
        elseif ($l -match '^CfgFile="(.+)"$') { $cfg = $Matches[1] -replace '\\\\', '\' }
        elseif ($l -match '^nic1="([^"]+)"') { $nic = $Matches[1] }
        elseif ($l -match '^"([^"]+)-(\d+)-(\d+)"="(.+)"$') {
            $ctl = $Matches[1]; $port = $Matches[2]; $dev = $Matches[3]; $pth = $Matches[4] -replace '\\\\', '\'
            if ($pth -match '\.(vdi|vhdx?|vmdk)$' -and -not $disk) { $disk = $pth }
            elseif ($pth -match '\.(iso|viso)$') { $media += [pscustomobject]@{ Ctl = $ctl; Port = $port; Dev = $dev; Leaf = Split-Path $pth -Leaf } }
        }
    }
    $vbq = "& `"$vbm`""
    if ($state -eq 'running') { OK "It is running." } else { Problem "It isn't running (state: $state)." @("$vbq startvm '$name' --type gui") }
    if ($disk) {
        $used = $null; foreach ($l in (NativeOut { & $vbm showmediuminfo disk $disk })) { if ($l -match '^Size on disk:\s*(\d+)\s*MBytes') { $used = [int64]$Matches[1] * 1MB } }
        if ($null -eq $used) { Info "Couldn't read how much of its disk is used." }
        elseif ($used -ge 3GB) { OK ("Ubuntu is on its disk ({0} used)." -f (Format-Size $used)) }
        else { Problem ("Its disk is almost empty ({0} used), so Ubuntu may not have installed." -f (Format-Size $used)) @("Open the VM window and look. If the installer is showing, finish it; otherwise build it again.") }
    } else { Problem "It has no disk attached." }
    if ($media) { foreach ($m in $media) { Problem "Install media is still attached ($($m.Leaf))." @("$vbq storageattach '$name' --storagectl $($m.Ctl) --port $($m.Port) --device $($m.Dev) --type dvddrive --medium emptydrive") } }
    else { OK "The install ISO is ejected." }
    $snap = @((NativeOut { & $vbm snapshot $name list --machinereadable }) | Where-Object { $_ -match '^SnapshotName(-[\d-]+)?="clean"' })
    if ($snap.Count -gt 1) { Problem "It has $($snap.Count) snapshots named 'clean', so a reset could pick the wrong one. Delete the newer ones in the VirtualBox app (Snapshots)." }
    elseif ($snap) { OK "It has a 'clean' snapshot to reset to." } else { Problem "It has no 'clean' snapshot to reset to." @("$vbq controlvm '$name' acpipowerbutton   (wait until it is off)", "$vbq snapshot '$name' take clean") }
    $dir = if ($cfg) { Split-Path $cfg -Parent } else { $null }
    $left = @(if ($dir) { Get-ChildItem -LiteralPath $dir -Filter 'Unattended-*' -File -ErrorAction SilentlyContinue })
    if ($left) { Problem "$($left.Count) unattended-install files are still in $dir. They can hold your password in plain text." @("Eject the install media first (above), then: Remove-Item '$dir\Unattended-*'") }
    else { OK "No unattended-install files are left in its folder." }
    if ($nic -and $nic -ne 'none') { OK "Its network is on ($nic)." } else { Problem "It has no network adapter." @("$vbq modifyvm '$name' --nic1 nat   (with the VM off)") }
    return $script:HealthProblems
}
function Show-Done([int]$problems, [string]$what) {
    Write-Host ""
    $color = if ($problems) { 'Yellow' } else { 'Green' }
    Write-Host $Rule -ForegroundColor $color
    if ($problems) { Write-Host "  BUILT, BUT $problems THING(S) NEED FIXING (see the health check above)" -ForegroundColor $color }
    else { Write-Host "  ALL DONE" -ForegroundColor $color }
    Write-Host $Rule -ForegroundColor $color
    if ($problems) { Warn "Run each 'Fix' line above in an Administrator PowerShell, in order." }
}

# ======================================================================= START
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { throw "Please run PowerShell as Administrator, then run this again. (Or add -DryRun to rehearse without changing anything.)" }

# Names known up front are secrets from the first line of the log.
Add-Secret $VMName 'vm'; Add-Secret $Username 'user'

# The log file is created once the save folder is chosen; until then lines are buffered.
Write-Log ("setup-ubuntu-vm log, started {0:yyyy-MM-dd HH:mm:ss}{1}, PowerShell {2}" -f (Get-Date), $(if ($DryRun) { ' (dry run)' } else { '' }), $PSVersionTable.PSVersion)
Write-Log "VM names, the login username and the password are replaced with <vm-N>, <user>, <password>."

$hasHyperVCmdlets = [bool](Get-Command New-VM -ErrorAction SilentlyContinue) -and [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
$hvFeature = $null; try { $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop } catch {}   # needs admin; HypervisorPresent covers it otherwise
$hvFeatureOn = $hvFeature -and ("$($hvFeature.State)" -eq 'Enabled')
$cs = Get-CimInstance Win32_ComputerSystem
$hypervisorOn = [bool]$cs.HypervisorPresent
$hvEnabled = $hasHyperVCmdlets -and ($hvFeatureOn -or $hypervisorOn)
$hostRamMB = [int]($cs.TotalPhysicalMemory / 1MB); $hostCpus = [int]$cs.NumberOfLogicalProcessors
$target = if ($hvEnabled) { "Hyper-V (fast on this PC)" } else { "VirtualBox" }

try {
    Section "Welcome - let's set up an Ubuntu virtual machine"
    if ($DryRun) {
        Write-Host "   DRY RUN: nothing will be created, deleted, converted or downloaded." -ForegroundColor Magenta
        Write-Host "   It stops before the build and prints what it would have done." -ForegroundColor Magenta
        if (-not $isAdmin) { Warn "Not running as Administrator: Hyper-V VMs can't be read, so the name check only sees VirtualBox and the folder." }
    }
    Info "This PC: $([math]::Round($hostRamMB/1024,1)) GB RAM, $hostCpus CPUs"
    Info "Will build on: $target"

    $vbManage = Get-VBoxManage

    if (-not $hvEnabled -and $hypervisorOn) {
        Write-Host ""
        Warn "A hypervisor (likely VBS/Credential Guard) is on but Hyper-V is off, so VirtualBox will be slow here."
        Warn "For full speed, enable Hyper-V (one reboot) then rerun:"
        Write-Host "     dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart"
        if ((Ask "Continue now with VirtualBox (slower)? (y/n)") -notmatch '^(y|yes)$') { Info "Stopped. Enable Hyper-V, reboot, then rerun."; return }
    }

    # ---- where to save (asked first: the space check, ISO reuse and name check all use it)
    Section "Where to save the VM"
    if ($PSBoundParameters.ContainsKey('WorkDir')) { $WorkDir = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\'); Info "Using $WorkDir (from -WorkDir)." }
    else { $WorkDir = Prompt-WorkDir $WorkDir }
    if (Test-Path -LiteralPath $WorkDir) { Start-Log $WorkDir }
    elseif ($DryRun) { Would "create the folder $WorkDir"; Info "A dry run doesn't create it, so this run's log isn't saved." ; $script:LogBuffer = $null }
    else { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null; OK "Created $WorkDir"; Start-Log $WorkDir }
    $isos = @(Get-ChildItem (Join-Path $WorkDir "ubuntu-*.iso") -ErrorAction SilentlyContinue)

    # ---- checks
    Section "Checking your machine"
    $dl = (Split-Path -Qualifier $WorkDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $dl).Free / 1GB, 1)
    $isoP = [bool](Get-ChildItem (Join-Path $WorkDir "ubuntu-*-desktop-amd64.iso") -ErrorAction SilentlyContinue)
    $needGB = if ($isoP) { 12 } else { 20 }
    if ($freeGB -lt $needGB) {
        $m = "Only $freeGB GB free on ${dl}:. Please free about $needGB GB and rerun."
        if ($DryRun) { Warn "$m (the real run would stop here)" } else { throw $m }
    } else { OK "Free space on ${dl}: $freeGB GB" }
    $online = $true
    try { Invoke-WebRequest "https://releases.ubuntu.com/" -UseBasicParsing -TimeoutSec 15 -Method Head | Out-Null } catch { try { Invoke-WebRequest "https://releases.ubuntu.com/" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { $online = $false } }
    if ($online) { OK "Internet connection OK" }
    else {
        $m = "No internet connection to releases.ubuntu.com. Check your connection and rerun."
        if ($DryRun) { Warn "$m (the real run would stop here)" } else { throw $m }
    }

    # ---- name (checked against both hypervisors and the folder)
    Section "Name your VM"
    $VMName = Prompt-VMName $VMName
    while ($true) {
        $conflict = Get-NameConflict $VMName
        if (-not $conflict.HvReadable) { Warn "Hyper-V couldn't be checked for '$VMName' (needs Administrator)." }
        if (-not $conflict.Any) { break }
        Write-Host ""
        Show-NameConflict $VMName $conflict
        Write-Host "     [r] Replace: delete the above and build the new VM"
        Write-Host "     [n] Change the name of this VM (keeps the above)"
        do { $ch = (Ask "Choice (r/n)").Trim().ToLower(); if ($ch -notin 'r', 'n') { Warn "Type r or n." } } until ($ch -in 'r', 'n')
        if ($ch -eq 'r') { break }
        Write-Host ""
        $VMName = Prompt-VMName $VMName
    }

    # ---- settings
    Section "Choose the VM's resources"
    $set = Choose-Settings $hostRamMB $hostCpus $MemoryMB $Cpus $DiskGB $UbuntuVersion
    $MemoryMB = $set.Mem; $Cpus = $set.Cpu; $DiskGB = $set.Disk; $UbuntuVersion = $set.Ver
    if ($MemoryMB -gt ($hostRamMB - 2048)) { $MemoryMB = [math]::Max(2048, $hostRamMB - 2048); Warn "Capped RAM to ${MemoryMB}MB to keep Windows stable." }
    if ($Cpus -gt ($hostCpus - 1)) { $Cpus = [math]::Max(1, $hostCpus - 1); Warn "Capped CPUs to $Cpus." }

    # ---- account
    Section "Create the login account"
    $acct = Prompt-Account $Username
    $Username = $acct.User; $Password = $acct.Password

    # ---- summary + confirm
    $osText = switch -regex ($UbuntuVersion) { '^\d+\.\d+$' { "Ubuntu $UbuntuVersion (Desktop)" } 'latest' { "Ubuntu (latest release, Desktop)" } default { "Ubuntu (latest LTS, Desktop)" } }
    Show-Summary $osText $target $WorkDir $MemoryMB $hostRamMB $Cpus $hostCpus $DiskGB $Username $VMName $conflict
    if ($DryRun) {
        Show-BuildPlan $hvEnabled $VMName $WorkDir $conflict $MemoryMB $Cpus $DiskGB $UbuntuVersion $isos
        Write-Host ""; OK "Dry run finished at 'Start the build?'. Nothing was changed."
        return
    }
    if ((Ask "Start the build? (y/n)") -notmatch '^(y|yes)$') { Info "No problem, nothing was built."; return }

    $script:StepNo = 0; $script:StepTotal = 5 + [int]$conflict.Any

    if ($hvEnabled) {
        # ---------------------------------------------------------- HYPER-V BUILD
        Step "Setting up networking"
        $switchName = Ensure-Switch; OK "Using switch '$switchName'"

        Step "Downloading Ubuntu"
        $iso = Get-UbuntuIso $UbuntuVersion $WorkDir; $isoPath = $iso.Path; $UbuntuVersion = $iso.Version

        Remove-Conflict $VMName $conflict
        $vmDir = Join-Path $WorkDir $VMName
        New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

        Step "Preparing the automatic install"
        # Only the hash goes into the install settings: the installer's review screen shows them.
        $pwHash = Get-Sha512Crypt $Password
        $userData = @"
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - openssh-server
  user-data:
    hostname: $VMName
    timezone: $TimeZone
    users:
      - name: $Username
        groups: [adm, sudo]
        shell: /bin/bash
        lock_passwd: false
        passwd: '$pwHash'
  shutdown: poweroff
"@
        $udPath = Join-Path $vmDir "user-data"; $mdPath = Join-Path $vmDir "meta-data"
        [IO.File]::WriteAllText($udPath, ($userData -replace "`r`n","`n"), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($mdPath, "instance-id: $VMName`nlocal-hostname: $VMName`n", (New-Object Text.UTF8Encoding($false)))
        $seedVhd = Join-Path $vmDir "seed.vhdx"
        New-VHD -Path $seedVhd -SizeBytes 64MB -Dynamic | Out-Null
        # Formatted before it is reachable, and reached through a temporary folder instead of a
        # drive letter, so Explorer never sees an empty new drive ("D:\ is not accessible").
        $mnt = Join-Path $env:TEMP ("cidata-" + [guid]::NewGuid().ToString('N'))
        $mounted = Mount-VHD -Path $seedVhd -NoDriveLetter -Passthru
        try {
            $diskNo = ($mounted | Get-Disk).Number
            Initialize-Disk -Number $diskNo -PartitionStyle MBR -ErrorAction SilentlyContinue | Out-Null
            $part = New-Partition -DiskNumber $diskNo -UseMaximumSize
            Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel CIDATA -Confirm:$false | Out-Null
            New-Item -ItemType Directory -Path $mnt | Out-Null
            Add-PartitionAccessPath -DiskNumber $diskNo -PartitionNumber $part.PartitionNumber -AccessPath "$mnt\"
            Copy-Item $udPath "$mnt\user-data" -Force; Copy-Item $mdPath "$mnt\meta-data" -Force
            Remove-PartitionAccessPath -DiskNumber $diskNo -PartitionNumber $part.PartitionNumber -AccessPath "$mnt\" -ErrorAction SilentlyContinue
        } finally {
            Dismount-VHD -Path $seedVhd -ErrorAction SilentlyContinue
            Remove-Item $mnt -Force -ErrorAction SilentlyContinue
        }
        # The seed disk now carries these; don't leave copies in the VM folder.
        Remove-Item $udPath, $mdPath -Force -ErrorAction SilentlyContinue
        OK "Install settings prepared."

        Step "Creating the virtual machine"
        $osVhd = Join-Path $vmDir "$VMName.vhdx"
        New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryMB*1MB) -NewVHDPath $osVhd -NewVHDSizeBytes ($DiskGB*1GB) -SwitchName $switchName -Path $WorkDir | Out-Null
        Set-VM -Name $VMName -StaticMemory -ErrorAction SilentlyContinue
        Set-VMProcessor -VMName $VMName -Count $Cpus
        Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
        Add-VMDvdDrive -VMName $VMName -Path $isoPath
        Add-VMHardDiskDrive -VMName $VMName -Path $seedVhd
        Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)
        Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction SilentlyContinue
        # Off: otherwise Windows checkpoints the VM on every start, which also traps the seed disk
        # inside a checkpoint and asks "revert or continue?" when the VM is started later.
        Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -ErrorAction SilentlyContinue
        $res = Get-HostResolution
        try { Set-VMVideo -VMName $VMName -HorizontalResolution $res[0] -VerticalResolution $res[1] -ResolutionType Single -ErrorAction Stop; Info "Screen size: $($res[0])x$($res[1]) (your monitor)." }
        catch { Warn "Couldn't set the screen size to $($res[0])x$($res[1]); it stays at Hyper-V's default (1024x768)." }
        OK "VM created."

        Step "Installing Ubuntu"
        Start-VM -Name $VMName | Out-Null; try { vmconnect.exe localhost $VMName } catch {}
        Warn "The installer may stop once on a 'Ready to install' screen: click Install there, then leave it."
        Info "Installing. The VM powers off by itself when done..."
        $prog = New-InstallProgress $VMName 'hv'; $done = $false
        do {
            Start-Sleep -Seconds 15
            $vmNow = Get-VM -Name $VMName
            if ("$($vmNow.State)" -eq 'Off') { $done = $true; break }
            # The system disk's current file (an .avhdx once a checkpoint exists), not the seed.
            $osNow = $vmNow | Get-VMHardDiskDrive | Where-Object { $_.Path -notlike '*\seed*' } | Select-Object -First 1
            Update-InstallProgress $prog ([int]$vmNow.CPUUsage) $(if ($osNow) { Get-VhdChainBytes $osNow.Path } else { 0 })
        } while (Test-InstallTime $prog)
        Microsoft.PowerShell.Utility\Write-Host ""
        if (-not $done) {
            $q = "'$VMName'"
            Warn "The install didn't finish in time (90 minutes after it started writing). The VM is left as it is."
            Write-Host "     When the install has finished and the VM is off, run these in an Administrator PowerShell:"
            foreach ($c in @("Get-VMDvdDrive -VMName $q | Remove-VMDvdDrive",
                             "Get-VMHardDiskDrive -VMName $q | Where-Object Path -like '*\seed*' | Remove-VMHardDiskDrive",
                             "Set-VMFirmware -VMName $q -FirstBootDevice (Get-VMHardDiskDrive -VMName $q | Select-Object -First 1)",
                             "Remove-Item '$seedVhd'",
                             "Checkpoint-VM -Name $q -SnapshotName clean",
                             "Start-VM -Name $q")) { Write-Host "       $c" }
            throw "Install did not finish in time."
        }
        OK ("Ubuntu installed in {0:hh\:mm\:ss}; the VM powered itself off." -f ((Get-Date) - $prog.Start))
        Info "Ejecting the install ISO and the seed disk..."
        # Each finishing step is on its own: one failing must not skip the rest. The health
        # check below reports anything left undone, with the command to fix it.
        [void](Try-Step "eject the install ISO" {
            # Ubuntu often ejects the disc itself at the end, and then removing the drive fails
            # with "cannot be found". An empty drive is fine; only a drive still holding the ISO matters.
            foreach ($d in @(Get-VMDvdDrive -VMName $VMName)) {
                try { Remove-VMDvdDrive -VMDvdDrive $d -ErrorAction Stop } catch { if ($d.Path) { Set-VMDvdDrive -VMDvdDrive $d -Path $null -ErrorAction Stop } }
            }
        })
        # By pattern, not exact path: a checkpoint would point the drive at seed_<id>.avhdx.
        [void](Try-Step "detach the seed disk" { Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -like '*\seed*' } | Remove-VMHardDiskDrive -ErrorAction Stop })
        [void](Try-Step "set the system disk as the boot disk" { Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1) -ErrorAction Stop })
        Remove-Item $seedVhd -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $seedVhd) { Warn "Couldn't delete $seedVhd; the health check below says how." }
        Info "Taking the 'clean' checkpoint..."
        [void](Try-Step "take the 'clean' checkpoint" { Checkpoint-VM -Name $VMName -SnapshotName "clean" -ErrorAction Stop })
        Info "Starting the VM and bringing its window up..."
        # Raise the window that is already open; a second one would ask "another user is connected".
        if (Try-Step "start the VM" { Start-VM -Name $VMName -ErrorAction Stop | Out-Null }) { [void](Show-VMWindow $VMName 'hv') }

        Show-Done (Test-HvBuild $VMName $vmDir)
        OK "'$VMName' (Ubuntu $UbuntuVersion) is on Hyper-V."
        OK "Log in with username '$Username' and your password."
        Write-Host "   Open later:  Hyper-V Manager, double-click '$VMName'"
        Write-Host "   Reset:       Restore-VMCheckpoint -VMName $VMName -Name clean -Confirm:`$false"
    }
    else {
        # ---------------------------------------------------------- VIRTUALBOX BUILD
        Step "Checking VirtualBox"
        $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        $VBoxManage = Get-VBoxManage
        if (-not $VBoxManage) {
            if (-not $haveWinget) { throw "winget not found. Install 'App Installer' from the Microsoft Store, or install VirtualBox from virtualbox.org, then rerun." }
            Info "Installing the latest VirtualBox (accept the admin prompts)..."
            winget install --id Microsoft.VCRedist.2015+.x64 -e --silent --accept-package-agreements --accept-source-agreements
            winget install --id Oracle.VirtualBox -e --accept-package-agreements --accept-source-agreements
            $VBoxManage = Get-VBoxManage
            if (-not $VBoxManage) { throw "VirtualBox installed but VBoxManage.exe not found. Reboot and rerun." }
        } elseif ($haveWinget) {
            Info "Updating VirtualBox to the latest if needed..."
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            winget upgrade --id Oracle.VirtualBox -e --accept-package-agreements --accept-source-agreements
            $ErrorActionPreference = $prev; $VBoxManage = Get-VBoxManage
        }
        OK "Using VirtualBox"
        function VBox { $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $out = & $VBoxManage @args 2>&1 } finally { $ErrorActionPreference = $prevEAP }; foreach ($line in $out) { $t = "$line".Trim(); if ($t) { Write-Host ("     " + (Redact $t -PasswordOnly)) -ForegroundColor DarkGray } }; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args[0]) failed (exit $LASTEXITCODE)." } }

        Step "Downloading Ubuntu"
        $iso = Get-UbuntuIso $UbuntuVersion $WorkDir; $isoPath = $iso.Path; $UbuntuVersion = $iso.Version

        Remove-Conflict $VMName $conflict

        Step "Creating the virtual machine"
        $vmDir = Join-Path $WorkDir $VMName; $vdiPath = Join-Path $vmDir "$VMName.vdi"
        Info "Registering VM..."; VBox createvm --name $VMName --ostype Ubuntu_64 --basefolder $WorkDir --register
        Info "Setting memory, CPUs, EFI, NAT..."; VBox modifyvm $VMName --memory $MemoryMB --cpus $Cpus --firmware efi --graphicscontroller vmsvga --vram 128 --clipboard-mode bidirectional --nic1 nat
        Info "Creating ${DiskGB}GB disk..."; VBox createmedium disk --filename $vdiPath --size ($DiskGB * 1024) --format VDI
        Info "Attaching disk and ISO..."; VBox storagectl $VMName --name SATA --add sata --controller IntelAhci
        VBox storageattach $VMName --storagectl SATA --port 0 --device 0 --type hdd --medium $vdiPath
        VBox storageattach $VMName --storagectl SATA --port 1 --device 0 --type dvddrive --medium $isoPath

        Step "Installing Ubuntu (automatic)"
        VBox unattended install $VMName --iso=$isoPath --user=$Username --password=$Password --full-user-name=$Username --hostname="$VMName.local" --locale=en_US --time-zone=$TimeZone --install-additions --start-vm=gui
        Info "Installing. This runs on its own..."
        $prog = New-InstallProgress $VMName 'vb'; $installed = $false
        do {
            Start-Sleep -Seconds 15
            $ga = NativeOut { & $VBoxManage guestproperty get $VMName "/VirtualBox/GuestAdd/Version" }
            if ($ga -match '^Value:') { $installed = $true; break }
            $bytes = [int64]0; foreach ($l in (NativeOut { & $VBoxManage showmediuminfo disk $vdiPath })) { if ($l -match '^Size on disk:\s*(\d+)\s*MBytes') { $bytes = [int64]$Matches[1] * 1MB } }
            Update-InstallProgress $prog $null $bytes
        } while (Test-InstallTime $prog)
        Microsoft.PowerShell.Utility\Write-Host ""
        if (-not $installed) { throw "Install did not finish in time (90 minutes after it started writing). Check the VM window." }
        OK ("Ubuntu installed in {0:hh\:mm\:ss}." -f ((Get-Date) - $prog.Start))

        Step "Saving a clean snapshot"
        Info "Ejecting the install ISO..."
        VBox storageattach $VMName --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
        Info "Shutting Ubuntu down for the snapshot (up to 5 minutes)..."
        VBox controlvm $VMName acpipowerbutton
        $sdStart = Get-Date; $deadline = $sdStart.AddMinutes(5); $forced = $false
        do {
            Start-Sleep -Seconds 5
            $info = NativeOut { & $VBoxManage showvminfo $VMName --machinereadable }; $state = ($info | Select-String '^VMState=' | Select-Object -First 1).ToString()
            $w = (Get-Width) - 1; Write-Host ("`r" + ("  {0:mm\:ss}   waiting for it to shut down" -f ((Get-Date) - $sdStart)).PadRight($w)) -NoNewline
            if ((Get-Date) -gt $deadline -and -not $forced) { Microsoft.PowerShell.Utility\Write-Host ""; Warn "It didn't shut down in 5 minutes, so it is being powered off."; VBox controlvm $VMName poweroff; $forced = $true }
        } until ($state -match 'poweroff')
        Microsoft.PowerShell.Utility\Write-Host ""
        Info "Taking the 'clean' snapshot..."
        VBox snapshot $VMName take clean --description "Clean Ubuntu install"
        Info "Starting the VM..."
        VBox startvm $VMName --type gui

        Show-Done (Test-VbBuild $VMName $VBoxManage)
        OK "'$VMName' (Ubuntu $UbuntuVersion) is on VirtualBox."
        OK "Log in with username '$Username' and your password."
        Write-Host "   Reset: & `"$VBoxManage`" snapshot $VMName restore clean"
    }
}
catch {
    Write-Log ""; Write-Log ("STOPPED: " + $_.Exception.Message)
    throw
}
finally {
    if ($script:LogPath) { Microsoft.PowerShell.Utility\Write-Host "`nA log of this run (names and password masked) was saved to $($script:LogPath)" -ForegroundColor DarkGray }
}
