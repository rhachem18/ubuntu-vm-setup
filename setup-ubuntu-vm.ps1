<#
.SYNOPSIS
  Guided setup for a clean Ubuntu Desktop VM, on Hyper-V or VirtualBox automatically.

.DESCRIPTION
  A step-by-step wizard anyone can follow. It detects the best hypervisor, shows the
  recommended settings (with your machine's limits), lets you accept or customize them,
  reuses an existing VM's size if you want, shows a plain summary, then builds.
    - Hyper-V enabled            -> builds on Hyper-V (native speed)
    - hypervisor forced on (VBS) -> warns to enable Hyper-V; VirtualBox would be slow
    - no hypervisor              -> builds on VirtualBox (full speed)
  Shared: latest Ubuntu LTS, verified ISO download, clean snapshot, logging to
  VMs\setup-log-*.txt. A menu also offers rename, delete and a health check (Doctor).

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
    if (-not $script:LogPath) { return }
    # The file is created with a UTF-8 BOM (so PS 5.1 shows the check marks right); appends add none.
    try { [IO.File]::AppendAllText($script:LogPath, (Redact $line) + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch {}
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
    function Test-IsoHash($p, $hh) { (Test-Path $p) -and ((Get-FileHash $p -Algorithm SHA256).Hash -eq $hh.ToUpper()) }
    $verified = $false
    for ($a = 1; $a -le 2 -and -not $verified; $a++) {
        if (Test-IsoHash $isoPath $hash) { OK "ISO present and verified, skipping download."; $verified = $true; break }
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
            Write-Host "`r  100%   download complete                                        "
        } catch {
            Write-Host "`nBITS unavailable ($($_.Exception.Message)). Trying curl..." -ForegroundColor Yellow
            & curl.exe -L --fail -o $isoPath $url
            if ($LASTEXITCODE -ne 0) { Warn "curl failed."; continue }
        }
        Info "Verifying checksum (about a minute)..."
        if (Test-IsoHash $isoPath $hash) { OK "Checksum OK."; $verified = $true } else { Warn "Checksum mismatch."; Remove-Item $isoPath -Force -ErrorAction SilentlyContinue }
    }
    if (-not $verified) { throw "Could not obtain a valid ISO after 2 attempts." }
    return [pscustomobject]@{ Path = $isoPath; Name = $isoName; Version = $ver }
}

# ---- wizard helpers -------------------------------------------------------
function Prompt-VMName($default) {
    do {
        $in = Ask "VM name [$default]" -Secret vm
        if ($in) { $default = $in.Trim() }
        $ok = $default -match '^[A-Za-z0-9._-]+$'
        if (-not $ok) { Warn "Letters, digits, dot, dash or underscore only." }
    } until ($ok)
    return $default
}
function Prompt-Account($defaultUser) {
    do {
        $in = Ask "Login username [$defaultUser]" -Secret user
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
function Get-ExistingVMSettings($name, $hvEnabled, $vbManage) {
    if ($hvEnabled -and (Get-VM -Name $name -ErrorAction SilentlyContinue)) {
        $mem = [int]((Get-VMMemory -VMName $name).Startup / 1MB)
        $cpu = (Get-VMProcessor -VMName $name).Count
        $disk = $null
        try { $p = (Get-VMHardDiskDrive -VMName $name | Select-Object -First 1).Path; if ($p) { $disk = [int]((Get-VHD $p).Size / 1GB) } } catch {}
        return [pscustomobject]@{ Found = $true; Where = 'Hyper-V'; Mem = $mem; Cpu = $cpu; Disk = $disk }
    }
    if ($vbManage) {
        $info = NativeOut { & $vbManage showvminfo $name --machinereadable }
        if ($LASTEXITCODE -eq 0 -and $info) {
            $mem = 0; $cpu = 0; $diskPath = $null
            foreach ($l in $info) {
                if ($l -match '^memory=(\d+)') { $mem = [int]$Matches[1] }
                if ($l -match '^cpus=(\d+)') { $cpu = [int]$Matches[1] }
                # First attached hard disk, e.g. "SATA-0-0"="C:\...\name.vdi"
                if (-not $diskPath -and $l -match '^"[^"]+-\d+-\d+"="(.+\.(vdi|vhdx?|vmdk))"$') { $diskPath = $Matches[1] -replace '\\\\', '\' }
            }
            $disk = $null
            if ($diskPath) {
                $mi = NativeOut { & $vbManage showmediuminfo disk $diskPath }
                foreach ($l in $mi) { if ($l -match '^Capacity:\s*(\d+)\s*MBytes') { $disk = [int][math]::Round([int64]$Matches[1] / 1024) } }
            }
            if ($mem -gt 0) { return [pscustomobject]@{ Found = $true; Where = 'VirtualBox'; Mem = $mem; Cpu = $cpu; Disk = $disk } }
        }
    }
    return [pscustomobject]@{ Found = $false }
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
        $in = (Ask ("$prompt [$default]")).Trim()
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
function Choose-Settings($hostRam, $hostCpu, $defMem, $defCpu, $defDisk, $defVer, $existing) {
    $recMem  = [math]::Min($defMem, [math]::Max(2048, $hostRam - 4096))
    $recCpu  = [math]::Min($defCpu, [math]::Max(1, $hostCpu - 1))
    Write-Host ""
    Show-SettingsTable "Recommended settings:" $recMem $recCpu $defDisk $hostRam $hostCpu
    Write-Host ("     Ubuntu version    latest LTS")
    if ($existing.Found) { Write-Host ""; Show-SettingsTable ("Your existing '" + $existing.Where + "' VM uses:") $existing.Mem $existing.Cpu $existing.Disk $hostRam $hostCpu }
    Write-Host ""
    Write-Host "   How do you want to set it up?"
    Write-Host "     [r] Use the recommended settings (default)"
    if ($existing.Found) { Write-Host "     [e] Reuse your existing VM's size" }
    Write-Host "     [c] Customize each setting"
    $choices = if ($existing.Found) { "r/e/c" } else { "r/c" }
    $pick = (Ask "Choice ($choices)").Trim().ToLower()
    if (-not $pick) { $pick = 'r' }

    if ($pick -eq 'e' -and $existing.Found) {
        return [pscustomobject]@{ Mem = $existing.Mem; Cpu = $existing.Cpu; Disk = $(if ($existing.Disk) { $existing.Disk } else { $defDisk }); Ver = $defVer }
    }
    if ($pick -eq 'c') {
        $maxMem = [math]::Max(2048, $hostRam - 2048)
        $maxCpu = [math]::Max(1, $hostCpu - 1)
        $mem = Read-IntOr "Memory in MB (1024 = 1 GB)" $recMem 2048 $maxMem
        $cpu = Read-IntOr "Number of CPUs" $recCpu 1 $maxCpu
        $disk = Read-IntOr "Disk size in GB" $defDisk 25 4096
        $verIn = (Ask "Ubuntu version: lts / latest / a number like 24.04 [$defVer]").Trim()
        if (-not $verIn) { $verIn = $defVer }
        return [pscustomobject]@{ Mem = $mem; Cpu = $cpu; Disk = $disk; Ver = $verIn }
    }
    return [pscustomobject]@{ Mem = $recMem; Cpu = $recCpu; Disk = $defDisk; Ver = $defVer }
}
function Show-Summary($osText, $target, $mem, $hostRam, $cpu, $hostCpu, $disk, $user, $name, $replaces, $replacesWhere, $leftoverDir) {
    Write-Host ""
    Write-Host $Rule -ForegroundColor Green
    Write-Host "  READY TO BUILD" -ForegroundColor Green
    Write-Host $Rule -ForegroundColor Green
    Write-Host ("  Operating system    {0}" -f $osText)
    Write-Host ("  Runs on             {0}" -f $target)
    Write-Host ("  Memory (RAM)        {0} GB     of your {1} GB" -f [math]::Round($mem/1024,1), [math]::Round($hostRam/1024,1))
    Write-Host ("  Processors          {0} CPUs    of your {1}" -f $cpu, $hostCpu)
    Write-Host ("  Disk size           {0} GB    (grows as needed)" -f $disk)
    Write-Host ("  Login username      {0}" -f $user)
    Write-Host ("  VM name             {0}" -f $name)
    if ($replaces) { Write-Host ("  Note                DELETES the existing {0} VM '{1}' and its disk" -f $replacesWhere, $name) -ForegroundColor Yellow }
    elseif ($leftoverDir) { Write-Host ("  Note                DELETES the leftover folder {0} (no VM uses it)" -f $leftoverDir) -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  This takes about 20 to 40 minutes. You can step away once it starts."
    Write-Host $Rule -ForegroundColor Green
}
function Show-BuildPlan($hvEnabled, $name, $WorkDir, $replaces, $replacesWhere, $leftoverDir, $mem, $cpu, $disk, $ver, $isos) {
    # DryRun stand-in for the build: mirrors the real build order, changes nothing.
    Write-Host ""
    Write-Host "   DRY RUN: the build would do the following" -ForegroundColor Magenta
    $vmDir = Join-Path $WorkDir $name
    if ($replaces) {
        if ($replacesWhere -eq 'VirtualBox') { Would "power off and unregister the VirtualBox VM '$name', deleting its disks" }
        else { Would "turn off and remove the Hyper-V VM '$name'" }
        if (Test-Path $vmDir) { Would "delete the folder $vmDir" }
    } elseif ($leftoverDir) { Would "delete the leftover folder $leftoverDir" }
    # Resolving the version is a read-only metadata lookup, and exercises the same parsing as a real run.
    $ver = Resolve-UbuntuVersion $ver
    $isoLine = if ($isos | Where-Object Name -like "ubuntu-$ver-desktop-*") { "reuse the saved Ubuntu $ver Desktop ISO if its SHA256 still matches (else re-download ~6 GB)" } else { "download the Ubuntu $ver Desktop ISO (~6 GB) into $WorkDir and verify its SHA256" }
    if ($hvEnabled) {
        Would "create the folder $vmDir"
        $hasDefault = $false; try { $hasDefault = [bool](Get-VMSwitch -Name "Default Switch" -ErrorAction Stop) } catch {}
        $sw = if ($hasDefault) { "use the 'Default Switch'" } else { "use the 'Default Switch', or create 'ubuntu-ext-switch' if it's missing" }
        Would $sw
        Would $isoLine
        Would "write a cloud-init seed (user-data, meta-data) to $vmDir\seed.vhdx (FAT32, label CIDATA)"
        Would "create the Gen2 Hyper-V VM '$name': $mem MB RAM, $cpu CPUs, $disk GB disk at $vmDir\$name.vhdx, Secure Boot UEFI CA"
        Would "boot the installer, wait up to 90 min for power-off, detach ISO + seed, take a 'clean' checkpoint, start the VM"
    } else {
        Would "install or update VirtualBox via winget if needed"
        Would $isoLine
        Would "register the VirtualBox VM '$name': $mem MB RAM, $cpu CPUs, EFI, NAT, $disk GB disk at $vmDir\$name.vdi"
        Would "run the unattended install, wait up to 90 min, eject the ISO, take a 'clean' snapshot, start the VM"
    }
}
function Remove-NamedVM($name, $WorkDir, $vbManage) {
    # Remove a VM of this name wherever it lives (Hyper-V and/or VirtualBox), then its folder.
    # This is what makes "replace" safe even when the clashing VM is on the other hypervisor
    # and shares the VMs\<name> folder.
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
function Ensure-Switch {
    $sw = "Default Switch"
    if (Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue) { return $sw }
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $nic) { throw "No active network adapter found to attach a switch to." }
    $sw = "ubuntu-ext-switch"
    if (-not (Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue)) { New-VMSwitch -Name $sw -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null }
    return $sw
}
# ---- actions (each one returns to the main menu) ------------------------------
# They read the run-wide facts ($hvEnabled, $vbManage, $hvVMs, $vbVMs, $isos, ...) set by the
# flow below. Assignments inside a function stay local, so every Create starts from the
# command-line defaults again.
function Invoke-Create {
    if (-not $hvEnabled -and $hypervisorOn) {
        Write-Host ""
        Warn "A hypervisor (likely VBS/Credential Guard) is on but Hyper-V is off, so VirtualBox will be slow here."
        Warn "For full speed, enable Hyper-V (one reboot) then rerun:"
        Write-Host "     dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart"
        if ((Ask "Continue now with VirtualBox (slower)? (y/n)") -notmatch '^(y|yes)$') { Info "Stopped. Enable Hyper-V, reboot, then rerun."; return }
    }

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

    # ---- name
    Section "Name your VM"
    $VMName = Prompt-VMName $VMName
    $existing = Get-ExistingVMSettings $VMName $hvEnabled $vbManage
    while ($existing.Found) {
        $buildingOn = if ($hvEnabled) { 'Hyper-V' } else { 'VirtualBox' }
        Warn "A VM named '$VMName' already exists in $($existing.Where)."
        if ($existing.Where -ne $buildingOn) {
            Warn "You're building on $buildingOn, and both use the folder VMs\$VMName, so replacing will DELETE the $($existing.Where) VM and its disk."
            Write-Host "     (To keep it, pick a different name.)"
        }
        Write-Host "     [r] Replace it (deletes the $($existing.Where) VM '$VMName')"
        Write-Host "     [n] Pick a different name (keeps it)"
        $clash = (Ask "Choice (r/n)").Trim().ToLower()
        if ($clash -eq 'r') { break }
        Write-Host ""
        $VMName = Prompt-VMName $VMName
        $existing = Get-ExistingVMSettings $VMName $hvEnabled $vbManage
    }
    $replaces = $existing.Found
    $replacesWhere = if ($replaces) { $existing.Where } else { $null }

    # ---- settings
    Section "Choose the VM's resources"
    $set = Choose-Settings $hostRamMB $hostCpus $MemoryMB $Cpus $DiskGB $UbuntuVersion $existing
    $MemoryMB = $set.Mem; $Cpus = $set.Cpu; $DiskGB = $set.Disk; $UbuntuVersion = $set.Ver
    if ($MemoryMB -gt ($hostRamMB - 2048)) { $MemoryMB = [math]::Max(2048, $hostRamMB - 2048); Warn "Capped RAM to ${MemoryMB}MB to keep Windows stable." }
    if ($Cpus -gt ($hostCpus - 1)) { $Cpus = [math]::Max(1, $hostCpus - 1); Warn "Capped CPUs to $Cpus." }

    # ---- account
    Section "Create the login account"
    $acct = Prompt-Account $Username
    $Username = $acct.User; $Password = $acct.Password

    # ---- summary + confirm
    $osText = switch -regex ($UbuntuVersion) { '^\d+\.\d+$' { "Ubuntu $UbuntuVersion (Desktop)" } 'latest' { "Ubuntu (latest release, Desktop)" } default { "Ubuntu (latest LTS, Desktop)" } }
    $vmDirPreview = Join-Path $WorkDir $VMName
    $leftoverDir = if (-not $replaces -and (Test-Path $vmDirPreview)) { $vmDirPreview } else { $null }
    Show-Summary $osText $target $MemoryMB $hostRamMB $Cpus $hostCpus $DiskGB $Username $VMName $replaces $replacesWhere $leftoverDir
    if ($DryRun) {
        Show-BuildPlan $hvEnabled $VMName $WorkDir $replaces $replacesWhere $leftoverDir $MemoryMB $Cpus $DiskGB $UbuntuVersion $isos
        Write-Host ""; OK "Dry run finished at 'Start the build?'. Nothing was changed."
        return
    }
    if ((Ask "Start the build? (y/n)") -notmatch '^(y|yes)$') { Info "No problem, nothing was built."; return }

    $script:StepNo = 0; $script:StepTotal = 6

    if ($hvEnabled) {
        # ---------------------------------------------------------- HYPER-V BUILD
        if ($replaces) { Remove-NamedVM $VMName $WorkDir $vbManage }
        $vmDir = Join-Path $WorkDir $VMName
        if (Test-Path $vmDir) { Remove-Item -Recurse -Force $vmDir -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

        Step "Setting up networking"
        $switchName = Ensure-Switch; OK "Using switch '$switchName'"

        Step "Downloading Ubuntu"
        $iso = Get-UbuntuIso $UbuntuVersion $WorkDir; $isoPath = $iso.Path; $UbuntuVersion = $iso.Version

        Step "Preparing the automatic install"
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
    chpasswd:
      expire: false
      users:
        - name: $Username
          password: "$Password"
          type: text
  shutdown: poweroff
"@
        $udPath = Join-Path $vmDir "user-data"; $mdPath = Join-Path $vmDir "meta-data"
        [IO.File]::WriteAllText($udPath, ($userData -replace "`r`n","`n"), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($mdPath, "instance-id: $VMName`nlocal-hostname: $VMName`n", (New-Object Text.UTF8Encoding($false)))
        $seedVhd = Join-Path $vmDir "seed.vhdx"
        New-VHD -Path $seedVhd -SizeBytes 64MB -Dynamic | Out-Null
        $mounted = Mount-VHD -Path $seedVhd -Passthru
        $diskNo = ($mounted | Get-Disk).Number
        Initialize-Disk -Number $diskNo -PartitionStyle MBR -ErrorAction SilentlyContinue | Out-Null
        $part = New-Partition -DiskNumber $diskNo -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel CIDATA -Confirm:$false | Out-Null
        $sd = "$($part.DriveLetter):"
        Copy-Item $udPath "$sd\user-data" -Force; Copy-Item $mdPath "$sd\meta-data" -Force
        Dismount-VHD -Path $seedVhd
        # The seed disk now carries these; don't leave the plaintext password in the VM folder.
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
        OK "VM created."

        Step "Installing Ubuntu"
        Start-VM -Name $VMName | Out-Null; try { vmconnect.exe localhost $VMName } catch {}
        Warn "If the installer asks to start the automated install, select yes once, then leave it."
        Info "Installing. The VM powers off by itself when done..."
        $start = Get-Date; $deadline = $start.AddMinutes(90); $done = $false
        do { Start-Sleep -Seconds 15; $state = (Get-VM -Name $VMName).State; $w = (Get-Width) - 1; $ln = ("  {0:hh\:mm\:ss} elapsed, VM state: {1}" -f ((Get-Date)-$start), $state); if ($ln.Length -gt $w) { $ln = $ln.Substring(0,$w) }; Write-Host ("`r" + $ln.PadRight($w)) -NoNewline; if ($state -eq 'Off') { $done = $true; break } } while ((Get-Date) -lt $deadline)
        Write-Host ""
        if (-not $done) { throw "Install did not finish within 90 minutes. Open the VM window to check; finish it, power off, then run: Checkpoint-VM -VMName $VMName -SnapshotName clean" }
        Get-VMDvdDrive -VMName $VMName | Remove-VMDvdDrive
        Get-VMHardDiskDrive -VMName $VMName | Where-Object Path -eq $seedVhd | Remove-VMHardDiskDrive
        Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1)
        Remove-Item $seedVhd -Force -ErrorAction SilentlyContinue
        Checkpoint-VM -Name $VMName -SnapshotName "clean"
        Start-VM -Name $VMName | Out-Null; try { vmconnect.exe localhost $VMName } catch {}

        Write-Host ""; Write-Host $Rule -ForegroundColor Green; Write-Host "  ALL DONE" -ForegroundColor Green; Write-Host $Rule -ForegroundColor Green
        OK "'$VMName' (Ubuntu $UbuntuVersion) is running on Hyper-V with a 'clean' checkpoint."
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
        if ($replaces) { Native { & $VBoxManage closemedium disk (Join-Path $WorkDir "$VMName\$VMName.vdi") --delete } | Out-Null; Remove-NamedVM $VMName $WorkDir $VBoxManage }

        Step "Downloading Ubuntu"
        $iso = Get-UbuntuIso $UbuntuVersion $WorkDir; $isoPath = $iso.Path; $UbuntuVersion = $iso.Version

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
        $start = Get-Date; $deadline = $start.AddMinutes(90); $installed = $false
        do { Start-Sleep -Seconds 15; $ga = NativeOut { & $VBoxManage guestproperty get $VMName "/VirtualBox/GuestAdd/Version" }; $w = (Get-Width) - 1; $ln = ("  {0:hh\:mm\:ss} elapsed" -f ((Get-Date)-$start)); Write-Host ("`r" + $ln.PadRight($w)) -NoNewline; if ($ga -match '^Value:') { $installed = $true; break } } while ((Get-Date) -lt $deadline)
        Write-Host ""
        if (-not $installed) { throw "Install did not complete within 90 minutes. Check the VM window." }
        OK "Ubuntu installed."

        Step "Saving a clean snapshot"
        VBox storageattach $VMName --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
        VBox controlvm $VMName acpipowerbutton
        $deadline = (Get-Date).AddMinutes(5)
        do { Start-Sleep -Seconds 5; $info = NativeOut { & $VBoxManage showvminfo $VMName --machinereadable }; $state = ($info | Select-String '^VMState=' | Select-Object -First 1).ToString(); if ((Get-Date) -gt $deadline) { VBox controlvm $VMName poweroff } } until ($state -match 'poweroff')
        VBox snapshot $VMName take clean --description "Clean Ubuntu install"
        VBox startvm $VMName --type gui

        Write-Host ""; Write-Host $Rule -ForegroundColor Green; Write-Host "  ALL DONE" -ForegroundColor Green; Write-Host $Rule -ForegroundColor Green
        OK "'$VMName' (Ubuntu $UbuntuVersion) is running on VirtualBox with a 'clean' snapshot."
        OK "Log in with username '$Username' and your password."
        Write-Host "   Reset: & `"$VBoxManage`" snapshot $VMName restore clean"
    }
}
# ---- doctor (read-only) ----------------------------------------------------------
function Format-Size([double]$bytes) { if ($bytes -gt 0 -and $bytes -lt 1MB) { "< 1 MB" } elseif ($bytes -lt 1GB) { "{0:N0} MB" -f ($bytes/1MB) } else { "{0:N1} GB" -f ($bytes/1GB) } }
function Get-DiskUsedBytes([string]$dir, [string[]]$files) {
    # Disk bytes in the VM's own folder, so snapshot/checkpoint layers count too. If the disk
    # sits straight in WorkDir (or a drive root), only count the attached files, or we'd add up
    # every other VM's disks as well.
    $exts = '.vdi', '.vhd', '.vhdx', '.avhdx', '.vmdk'
    if ($dir -and (Test-Path -LiteralPath $dir) -and $dir.TrimEnd('\') -ne $WorkDir.TrimEnd('\') -and (Split-Path $dir -Parent)) {
        $sum = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) { if ($f.Extension -in $exts -and $f.Name -ne 'seed.vhdx') { $sum += $f.Length } }
        return $sum
    }
    $sum = 0; foreach ($p in $files) { if ($p -and (Test-Path -LiteralPath $p)) { $sum += (Get-Item -LiteralPath $p).Length } }
    return $sum
}
function Get-HvHealth($name) {
    $vm = Get-VM -Name $name -ErrorAction Stop
    $drives = @($vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue)
    $seed = @($drives | Where-Object { $_.Path -like '*\seed.vhdx' })
    $os = $drives | Where-Object { $_.Path -notlike '*\seed.vhdx' } | Select-Object -First 1
    $cap = $null; if ($os) { try { $cap = (Get-VHD -Path $os.Path -ErrorAction Stop).Size } catch {} }
    $dirs = @("$($vm.Path)"); if ($os) { $dirs += Split-Path $os.Path -Parent }
    [pscustomobject]@{
        Name = $name; Where = 'Hyper-V'; State = "$($vm.State)".ToLower(); Running = ("$($vm.State)" -ne 'Off'); Aborted = $false
        MemMB = [int]($vm.MemoryStartup / 1MB); Cpus = $vm.ProcessorCount
        DiskPath = $(if ($os) { $os.Path }); CapBytes = $cap
        UsedBytes = $(if ($os) { Get-DiskUsedBytes (Split-Path $os.Path -Parent) @($os.Path) } else { 0 })
        Snapshots = @($vm | Get-VMSnapshot -ErrorAction SilentlyContinue).Count; SnapWord = 'checkpoint'
        Media = @($vm | Get-VMDvdDrive -ErrorAction SilentlyContinue | Where-Object Path | ForEach-Object { Split-Path $_.Path -Leaf })
        SeedLeft = [bool]$seed; Unattended = 0; Dirs = $dirs
    }
}
function Get-VbHealth($name) {
    $info = NativeOut { & $vbManage showvminfo $name --machinereadable }
    if ($LASTEXITCODE -ne 0 -or -not $info) { throw "VBoxManage could not read it" }
    $state = '?'; $mem = 0; $cpu = 0; $cfg = $null; $disks = @(); $media = @()
    foreach ($l in $info) {
        if ($l -match '^VMState="([^"]+)"') { $state = $Matches[1] }
        elseif ($l -match '^memory=(\d+)') { $mem = [int]$Matches[1] }
        elseif ($l -match '^cpus=(\d+)') { $cpu = [int]$Matches[1] }
        elseif ($l -match '^CfgFile="(.+)"$') { $cfg = $Matches[1] -replace '\\\\', '\' }
        # Attachments look like "SATA-0-0"="C:\\...\\disk.vdi"; "none"/"emptydrive" are empty slots.
        elseif ($l -match '^"[^"]+-\d+-\d+"="(.+)"$') {
            $p = $Matches[1] -replace '\\\\', '\'
            if ($p -match '\.(vdi|vhdx?|vmdk)$') { $disks += $p } elseif ($p -match '\.(iso|viso|dmg)$') { $media += (Split-Path $p -Leaf) }
        }
    }
    $cap = $null
    if ($disks) { foreach ($l in (NativeOut { & $vbManage showmediuminfo disk $disks[0] })) { if ($l -match '^Capacity:\s*(\d+)\s*MBytes') { $cap = [int64]$Matches[1] * 1MB } } }
    $snaps = @((NativeOut { & $vbManage snapshot $name list --machinereadable }) | Where-Object { $_ -match '^SnapshotName' }).Count
    $dir = if ($cfg) { Split-Path $cfg -Parent } else { $null }
    $unatt = if ($dir -and (Test-Path -LiteralPath $dir)) { @(Get-ChildItem -LiteralPath $dir -Filter 'Unattended-*' -File -ErrorAction SilentlyContinue).Count } else { 0 }
    $stateText = switch ($state) { 'poweroff' { 'off' } 'saved' { 'saved (suspended)' } default { $state } }
    [pscustomobject]@{
        Name = $name; Where = 'VirtualBox'; State = $stateText; Running = ($state -notin 'poweroff', 'aborted', 'saved'); Aborted = ($state -eq 'aborted')
        MemMB = $mem; Cpus = $cpu; DiskPath = $(if ($disks) { $disks[0] }); CapBytes = $cap
        UsedBytes = $(if ($disks) { Get-DiskUsedBytes $dir $disks } else { 0 })
        Snapshots = $snaps; SnapWord = 'snapshot'; Media = $media; SeedLeft = $false; Unattended = $unatt; Dirs = @($dir)
    }
}
function Show-VMHealth($h) {
    Write-Host ""
    Write-Host ("   {0}  ({1})" -f $h.Name, $h.Where) -ForegroundColor White
    Write-Host ("     State            {0}" -f $h.State)
    Write-Host ("     Memory, CPUs     {0} MB, {1} CPUs" -f $h.MemMB, $h.Cpus)
    $capText = if ($h.CapBytes) { Format-Size $h.CapBytes } else { 'unknown size' }
    if ($h.DiskPath) { Write-Host ("     Disk             {0} used of {1}" -f (Format-Size $h.UsedBytes), $capText) } else { Write-Host "     Disk             none attached" }
    Write-Host ("     {0,-17}{1}" -f ($h.SnapWord.Substring(0,1).ToUpper() + $h.SnapWord.Substring(1) + 's'), $(if ($h.Snapshots) { $h.Snapshots } else { 'none' }))
    Write-Host ("     Install media    {0}" -f $(if ($h.Media) { 'attached: ' + ($h.Media -join ', ') } else { 'none' }))
    $n = 0
    function Flag($m) { Warn $m; Set-Variable -Name n -Value ($n + 1) -Scope 1 }
    $empty = $h.DiskPath -and $h.UsedBytes -lt 1GB
    if (-not $h.DiskPath) { Flag "It has no disk attached, so it can't boot." }
    elseif (-not (Test-Path -LiteralPath $h.DiskPath)) { Flag "Its disk file is missing: $($h.DiskPath)" }
    elseif ($empty) {
        Flag ("Its disk is almost empty ({0} used), so Ubuntu was never fully installed{1}." -f (Format-Size $h.UsedBytes), $(if ($h.Running) { ' (unless the install is running right now)' } else { '' }))
        Write-Host "       Fix: delete it with [3] and create it again with [1]."
    }
    if ($h.Media) { Flag "Install media is still attached. After the install the VM can boot back into the installer; eject it." }
    if ($h.SeedLeft) { Flag "The install seed disk (seed.vhdx) is still attached. It holds the login password in plain text." }
    if ($h.Unattended) { Flag "$($h.Unattended) unattended-install files are still in its folder. They can hold the login password in plain text." }
    if ($h.Aborted) { Flag "It crashed or was killed the last time it ran." }
    if (-not $h.Snapshots -and -not $empty -and $h.DiskPath) { Flag "No $($h.SnapWord), so there is nothing to roll back to." }
    if ($h.Where -eq 'VirtualBox' -and $hypervisorOn) {
        if ($hvEnabled) { Flag "It runs on VirtualBox on top of the Windows hypervisor, which is slow here. New VMs built with [1] use Hyper-V instead." }
        else { Flag "It runs on VirtualBox on top of the Windows hypervisor, which is slow here. Enabling Hyper-V would be faster." }
    }
    if (-not $n) { OK "No problems found." }
    return $n
}
function Invoke-Doctor {
    # Pure diagnosis: reads VM settings and file sizes, changes nothing (so no -DryRun branch).
    Info "This only reads; nothing is changed."
    $issues = 0
    Write-Host ""; Write-Host "   This PC" -ForegroundColor White
    $dl = (Split-Path -Qualifier $WorkDir).TrimEnd(':')
    $free = (Get-PSDrive $dl).Free
    Write-Host ("     {0,-17}{1}" -f "Free on ${dl}:", (Format-Size $free))
    if ($free -lt 20GB) { Warn "Less than 20 GB free on ${dl}:. A new VM needs about 20 GB."; $issues++ }
    if ($hvEnabled) { Write-Host "     Hypervisor       Hyper-V is on" }
    elseif ($hypervisorOn) { Write-Host "     Hypervisor       on (VBS/Credential Guard), but Hyper-V is off"; Warn "VirtualBox VMs run slowly here. Enabling Hyper-V would be faster."; $issues++ }
    else { Write-Host "     Hypervisor       none (VirtualBox runs at full speed)" }
    foreach ($i in $isos) { Write-Host ("     Saved ISO        {0} ({1})" -f $i.Name, (Format-Size $i.Length)) }

    $usedDirs = @(); $hvChecked = $false
    if (-not $hasHyperVCmdlets) { }
    elseif (-not $hvReadable) { Write-Host ""; Warn "Hyper-V VMs: can't read them. Run PowerShell as Administrator to check them too."; $issues++ }
    else {
        $hvChecked = $true
        foreach ($n in $hvVMs) {
            try { $h = Get-HvHealth $n; $issues += Show-VMHealth $h; $usedDirs += $h.Dirs }
            catch { Write-Host ""; Warn "Hyper-V VM '$n': can't read it ($($_.Exception.Message))"; $issues++ }
        }
    }
    if ($vbManage) {
        foreach ($n in $vbVMs) {
            try { $h = Get-VbHealth $n; $issues += Show-VMHealth $h; $usedDirs += $h.Dirs }
            catch { Write-Host ""; Warn "VirtualBox VM '$n': can't read it ($($_.Exception.Message))"; $issues++ }
        }
    }
    if (-not $hvVMs -and -not $vbVMs) { Write-Host ""; Info "No VMs found." }

    # Folders under WorkDir that no VM uses (left behind by a failed build or a manual delete).
    $orphans = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $WorkDir -Directory -ErrorAction SilentlyContinue)) {
        $f = $d.FullName.TrimEnd('\')
        $used = $false
        foreach ($u in $usedDirs) { if ($u -and ($u.TrimEnd('\') -eq $f -or $u.StartsWith("$f\", [StringComparison]::OrdinalIgnoreCase))) { $used = $true } }
        if (-not $used) { $orphans += $d }
    }
    if ($orphans) {
        Write-Host ""; Write-Host "   Folders in $WorkDir that no VM uses" -ForegroundColor White
        foreach ($d in $orphans) {
            Add-Secret $d.Name 'vm'
            $size = Get-FolderBytes $d.FullName
            Warn ("{0} ({1}){2}" -f $d.Name, (Format-Size $size), $(if ($hvChecked -or -not $hasHyperVCmdlets) { '' } else { ", not used by VirtualBox; Hyper-V couldn't be checked" }))
            $issues++
        }
        Write-Host "       These are usually left over from a failed build. [3] can delete them."
    }

    Write-Host ""
    if ($issues) { Warn "$issues thing(s) worth a look." } else { OK "Everything looks healthy." }
}
function Invoke-Rename {
    # Renames the VM itself, never its disk files. Hyper-V leaves the folder alone too;
    # VirtualBox moves its own folder and settings file along when they carry the old name
    # (that's VirtualBox's behaviour, not ours), so we say which one applies.
    $list = @()
    foreach ($n in $hvVMs) { $list += [pscustomobject]@{ Name = $n; Where = 'Hyper-V' } }
    foreach ($n in $vbVMs) { $list += [pscustomobject]@{ Name = $n; Where = 'VirtualBox' } }
    if ($hasHyperVCmdlets -and -not $hvReadable) { Warn "Hyper-V VMs can't be read without Administrator, so only VirtualBox VMs are listed." }
    if (-not $list) { Info "There are no VMs to rename."; return }
    Info "This changes the VM's name only. The VM must be turned off."
    for ($k = 0; $k -lt $list.Count; $k++) { Write-Host ("     [{0}] {1}  ({2})" -f ($k+1), $list[$k].Name, $list[$k].Where) }
    $pick = $null
    do {
        $pk = (Ask "Which VM? Enter its number (Enter to go back)").Trim()
        if (-not $pk) { return }
        if ($pk -match '^\d+$' -and [int]$pk -ge 1 -and [int]$pk -le $list.Count) { $pick = $list[[int]$pk-1] } else { Warn "Enter a number from the list." }
    } until ($pick)
    $name = $pick.Name
    try { $h = if ($pick.Where -eq 'Hyper-V') { Get-HvHealth $name } else { Get-VbHealth $name } }
    catch { Warn "Can't read '$name' ($($_.Exception.Message)). Nothing renamed."; return }
    if ($h.State -notin 'off', 'aborted') {
        Warn "'$name' is $($h.State). Shut it down first (from inside Ubuntu), then try again."
        if (-not $DryRun) { return }
        Warn "(the real run would stop here; the dry run carries on)"
    }
    $new = $null
    do {
        $in = (Ask "New name for '$name' (Enter to go back)" -Secret vm).Trim()
        if (-not $in) { return }
        $bad = $null
        if ($in -notmatch '^[A-Za-z0-9._-]+$' -or $in -match '^\.+$') { $bad = "Letters, digits, dot, dash or underscore only." }
        elseif ($in -eq $name) { $bad = "That's already its name." }
        elseif ((@($hvVMs) + @($vbVMs)) -contains $in) { $bad = "A VM named '$in' already exists." }
        elseif (Test-Path -LiteralPath (Join-Path $WorkDir $in)) { $bad = "A folder named '$in' already exists in $WorkDir. Pick another name, or delete that folder first." }
        if ($bad) { Warn $bad } else { $new = $in }
    } until ($new)
    if ($hasHyperVCmdlets -and -not $hvReadable) { Warn "Couldn't check Hyper-V for a VM already named '$new'." }

    $dir = $h.Dirs | Select-Object -First 1
    $diskLeaf = if ($h.DiskPath) { Split-Path $h.DiskPath -Leaf } else { $null }
    $vbMovesDir = $pick.Where -eq 'VirtualBox' -and $dir -and ((Split-Path $dir -Leaf) -eq $name)
    $newDir = if ($vbMovesDir) { Join-Path (Split-Path $dir -Parent) $new } else { $null }
    Write-Host ""
    if ($vbMovesDir) {
        Info "VirtualBox also renames its folder to $newDir, and its settings file."
        if ($diskLeaf) { Info "The disk file keeps its old name: $diskLeaf" }
    } else {
        Info "Its folder and disk files keep the old name$(if ($h.DiskPath) { ": $($h.DiskPath)" })."
    }
    if ((Ask "Rename the $($pick.Where) VM '$name' to '$new'? (y/n)") -notmatch '^(y|yes)$') { Info "Nothing renamed."; return }
    if ($DryRun) {
        Would "rename the $($pick.Where) VM '$name' to '$new'"
        if ($vbMovesDir) { Would "let VirtualBox move its folder to $newDir" }
        OK "Dry run: nothing was changed."
        return
    }
    if ($pick.Where -eq 'Hyper-V') {
        try { Get-VM -Name $name -ErrorAction Stop | Rename-VM -NewName $new -ErrorAction Stop; OK "Renamed '$name' to '$new'." }
        catch { Warn "Hyper-V couldn't rename it: $($_.Exception.Message)" }
    } else {
        $rc = Native { & $vbManage modifyvm $name --name $new }
        if ($rc -eq 0) { OK "Renamed '$name' to '$new'." } else { Warn "VirtualBox couldn't rename it (exit $rc). Nothing changed." }
    }
}
# ---- delete --------------------------------------------------------------------
function Get-FolderBytes([string]$dir) {
    $sum = 0; foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $sum += $f.Length }; return $sum
}
function Get-TopDir([string]$p) {
    # The folder directly inside WorkDir that holds $p, or $null if $p is outside WorkDir.
    # Deletes only ever remove folders this returns, so they can't reach WorkDir itself or beyond.
    if (-not $p) { return $null }
    $root = [IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
    try { $full = [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return $null }
    if (-not $full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $seg = $full.Substring($root.Length + 1).Split('\')[0]
    if (-not $seg -or $seg -match '^\.+$') { return $null }
    return (Join-Path $root $seg)
}
function Remove-SafeFolder([string]$dir) {
    $top = Get-TopDir $dir
    if (-not $top -or $top -ne $dir.TrimEnd('\')) { Warn "Not deleting ${dir}: it isn't a folder directly inside $WorkDir."; return }
    if (-not (Test-Path -LiteralPath $dir)) { return }
    if ($DryRun) { Would ("delete the folder {0} ({1})" -f $dir, (Format-Size (Get-FolderBytes $dir))); return }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dir) { Warn "Some files in $dir couldn't be deleted (in use?). Close any VM window and try again." }
    else { OK "Deleted the folder $dir" }
}
function Remove-VMItem($it, [string[]]$keepDirs) {
    # Removes the VM from its hypervisor, then its own folder(s) in WorkDir, unless another VM
    # still uses that folder (same-name VMs on both hypervisors share VMs\<name>).
    $name = $it.Name
    if ($it.Where -eq 'Hyper-V') {
        if ($DryRun) { Would "turn off and remove the Hyper-V VM '$name' and its checkpoints" }
        else {
            try {
                $vm = Get-VM -Name $name -ErrorAction Stop
                if ("$($vm.State)" -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop }
                Remove-VM -VM $vm -Force -ErrorAction Stop
                OK "Removed the Hyper-V VM '$name'."
            } catch { Warn "Couldn't remove the Hyper-V VM '$name' ($($_.Exception.Message)). Its files were left alone."; return }
        }
    } else {
        # Files outside WorkDir are never deleted: such a VM is only unregistered.
        $inside = [bool]$it.Dirs
        if ($DryRun) { Would "power off and unregister the VirtualBox VM '$name'$(if ($inside) { ', deleting its disks' })" }
        else {
            if ($it.Health.Running) { Native { & $vbManage controlvm $name poweroff } | Out-Null; Start-Sleep -Seconds 2 }
            $rc = if ($inside) { Native { & $vbManage unregistervm $name --delete } } else { Native { & $vbManage unregistervm $name } }
            if ($rc -ne 0) { Warn "VirtualBox couldn't remove '$name' (exit $rc). Its files were left alone."; return }
            OK "Removed the VirtualBox VM '$name'$(if ($inside) { ' and its disks' })."
        }
    }
    foreach ($d in $it.Dirs) {
        if ($keepDirs -contains $d) { Info "Keeping the folder $d, because another VM uses it." }
        else { Remove-SafeFolder $d }
    }
    if (-not $it.Dirs -and $it.Health.DiskPath) { Info "Its files in $(Split-Path $it.Health.DiskPath -Parent) are outside $WorkDir and are left in place." }
}
function Invoke-Delete {
    # One numbered list of everything deletable, with sizes; pick several at once.
    $vmItems = @(); $protect = @()
    if ($hasHyperVCmdlets -and -not $hvReadable) { Warn "Hyper-V VMs can't be read without Administrator, so they aren't listed, and a folder below may belong to one." }
    $all = @()
    foreach ($n in $hvVMs) { $all += [pscustomobject]@{ Name = $n; Where = 'Hyper-V' } }
    foreach ($n in $vbVMs) { $all += [pscustomobject]@{ Name = $n; Where = 'VirtualBox' } }
    foreach ($v in $all) {
        try { $h = if ($v.Where -eq 'Hyper-V') { Get-HvHealth $v.Name } else { Get-VbHealth $v.Name } }
        catch { Warn "Can't read the $($v.Where) VM '$($v.Name)', so it isn't listed."; $protect += Get-TopDir (Join-Path $WorkDir $v.Name); continue }
        $cands = @($h.Dirs); if ($h.DiskPath) { $cands += Split-Path $h.DiskPath -Parent }
        $tops = @($cands | ForEach-Object { Get-TopDir $_ } | Where-Object { $_ } | Sort-Object -Unique)
        $size = $h.UsedBytes
        if ($tops) { $size = 0; foreach ($t in $tops) { $size += Get-FolderBytes $t } }
        $vmItems += [pscustomobject]@{ Kind = 'vm'; Name = $v.Name; Where = $v.Where; Label = "$($v.Where) VM"; Size = $size; Dirs = $tops; Health = $h }
    }
    $used = @($vmItems | ForEach-Object { $_.Dirs }) + @($protect | Where-Object { $_ })
    $items = @($vmItems)
    foreach ($d in @(Get-ChildItem -LiteralPath $WorkDir -Directory -ErrorAction SilentlyContinue)) {
        if ($used -contains $d.FullName) { continue }
        Add-Secret $d.Name 'vm'
        $items += [pscustomobject]@{ Kind = 'folder'; Name = $d.Name; Label = 'folder, no VM'; Size = (Get-FolderBytes $d.FullName); Dirs = @($d.FullName) }
    }
    foreach ($i in $isos) { $items += [pscustomobject]@{ Kind = 'iso'; Name = $i.Name; Label = 'ISO'; Size = $i.Length; Path = $i.FullName } }
    if (-not $items) { Info "Nothing to delete."; return }

    $w = [math]::Max(12, [math]::Min(34, ($items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum))
    for ($k = 0; $k -lt $items.Count; $k++) { Write-Host ("     [{0}] {1} {2,-16} {3,9}" -f ($k+1), $items[$k].Name.PadRight($w), $items[$k].Label, (Format-Size $items[$k].Size)) }
    Write-Host "     [a] EVERYTHING under $WorkDir (keeps the logs)"
    $sel = $null; $everything = $false
    do {
        $in = (Ask "Numbers to delete, like 1,3 or 2-4 (a = everything, Enter to go back)").Trim().ToLower()
        if (-not $in) { return }
        if ($in -eq 'a') { $everything = $true; break }
        $idx = @(); $bad = $false
        foreach ($tok in ($in -split '[,\s]+' | Where-Object { $_ })) {
            if ($tok -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le [int]$Matches[2]) { $idx += [int]$Matches[1]..[int]$Matches[2] }
            elseif ($tok -match '^\d+$') { $idx += [int]$tok }
            else { $bad = $true }
        }
        if ($bad -or -not $idx -or ($idx | Where-Object { $_ -lt 1 -or $_ -gt $items.Count })) { Warn "Use numbers from the list (1 to $($items.Count)), separated by commas." }
        else { $sel = @($idx | Sort-Object -Unique | ForEach-Object { $items[$_ - 1] }) }
    } until ($sel)

    if ($everything) {
        Write-Host ""
        Warn "This permanently deletes ALL VMs, folders and ISOs under $WorkDir (logs are kept)."
        if ($hasHyperVCmdlets -and -not $hvReadable) { Warn "Hyper-V VMs couldn't be read, so they aren't included." }
        if ((Ask "Type 'yes' to confirm") -ne 'yes') { Info "Nothing deleted."; return }
        $done = @()
        foreach ($it in $vmItems) { Remove-VMItem $it @(); $done += $it.Dirs }
        foreach ($f in @(Get-ChildItem -LiteralPath $WorkDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'setup-log-*.txt' })) {
            if ($done -contains $f.FullName) { continue }
            if ($f.PSIsContainer) { Remove-SafeFolder $f.FullName }
            elseif ($DryRun) { Would ("delete {0} ({1})" -f $f.FullName, (Format-Size $f.Length)) }
            else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $f.FullName) { Warn "Couldn't delete $($f.FullName)." } else { OK "Deleted $($f.Name)" } }
        }
        if ($DryRun) { OK "Dry run: nothing was changed." } else { Info "Logs (setup-log-*.txt) were kept." }
        return
    }

    Write-Host ""
    Write-Host "   You picked:"
    $total = 0
    foreach ($it in $sel) { Write-Host ("     {0} {1,-16} {2,9}" -f $it.Name.PadRight($w), $it.Label, (Format-Size $it.Size)); $total += $it.Size }
    Write-Host ("     Frees about {0}" -f (Format-Size $total))
    $keep = @($vmItems | Where-Object { $sel -notcontains $_ } | ForEach-Object { $_.Dirs })
    foreach ($it in @($sel | Where-Object Kind -eq 'vm')) { foreach ($d in $it.Dirs) { if ($keep -contains $d) { Info "'$($it.Name)' shares $d with another VM; that folder will be kept." } } }
    foreach ($it in @($sel | Where-Object Kind -eq 'iso')) { foreach ($v in $vmItems) { if ($v.Health.Media -contains $it.Name) { Warn "$($it.Name) is attached to '$($v.Name)'." } } }
    if ((Ask "Delete these $($sel.Count) item(s)? This can't be undone. (y/n)") -notmatch '^(y|yes)$') { Info "Nothing deleted."; return }
    foreach ($it in $sel) {
        switch ($it.Kind) {
            'vm'     { Remove-VMItem $it $keep }
            'folder' { Remove-SafeFolder $it.Dirs[0] }
            'iso'    {
                if ($DryRun) { Would ("delete {0} ({1})" -f $it.Path, (Format-Size $it.Size)) }
                else { Remove-Item -LiteralPath $it.Path -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $it.Path) { Warn "Couldn't delete $($it.Name) (in use?)." } else { OK "Deleted $($it.Name)" } }
            }
        }
    }
    if ($DryRun) { OK "Dry run: nothing was changed." }
}
function Update-Inventory {
    # Re-read every time the menu is shown, so it reflects what the last action changed.
    $script:vbManage = Get-VBoxManage
    $script:hvVMs = @(); $script:hvReadable = $true
    if ($hasHyperVCmdlets) { try { $script:hvVMs = @(Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name) } catch { $script:hvReadable = $false } }
    $script:vbVMs = @(); if ($script:vbManage) { $script:vbVMs = @((NativeOut { & $script:vbManage list vms }) | ForEach-Object { if ($_ -match '^"([^"]+)"') { $Matches[1] } }) }
    $script:isos = @(Get-ChildItem (Join-Path $WorkDir "ubuntu-*.iso") -ErrorAction SilentlyContinue)
    foreach ($n in @($script:hvVMs) + @($script:vbVMs)) { Add-Secret $n 'vm' }
    if (-not $script:hvReadable) { Warn "Hyper-V VMs: can't read them (needs Administrator)" }
    elseif ($script:hvVMs) { Info ("Hyper-V VMs: " + ($script:hvVMs -join ', ')) } else { Info "Hyper-V VMs: none" }
    if ($script:vbVMs) { Info ("VirtualBox VMs: " + ($script:vbVMs -join ', ')) } else { Info "VirtualBox VMs: none" }
    if ($script:isos) { foreach ($i in $script:isos) { Info ("Saved ISO: {0} ({1:N0} MB)" -f $i.Name, ($i.Length/1MB)) } } else { Info "Saved ISOs: none" }
}

# ======================================================================= START
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { throw "Please run PowerShell as Administrator, then run this again. (Or add -DryRun to rehearse without changing anything.)" }

# Names known up front are secrets from the first line of the log.
Add-Secret $VMName 'vm'; Add-Secret $Username 'user'

# A dry run only writes its log, and only into a WorkDir that already exists.
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
if (Test-Path $WorkDir) {
    $logPath = Join-Path $WorkDir ("setup-log-{0:yyyyMMdd-HHmmss}{1}.txt" -f (Get-Date), $(if ($DryRun) { '-dryrun' } else { '' }))
    [IO.File]::WriteAllBytes($logPath, [byte[]](0xEF, 0xBB, 0xBF))
    $script:LogPath = $logPath
    Write-Log ("setup-ubuntu-vm log, started {0:yyyy-MM-dd HH:mm:ss}{1}, PowerShell {2}" -f (Get-Date), $(if ($DryRun) { ' (dry run)' } else { '' }), $PSVersionTable.PSVersion)
    Write-Log "VM names, the login username and the password are replaced with <vm-N>, <user>, <password>."
}

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
        Write-Host "   Each action prints what it would have done instead." -ForegroundColor Magenta
        if (-not $isAdmin) { Warn "Not running as Administrator: Hyper-V VMs can't be listed, so clash checks only see VirtualBox." }
    }
    Info "This PC: $([math]::Round($hostRamMB/1024,1)) GB RAM, $hostCpus CPUs"
    Info "Will build on: $target"

    # ---- main menu: each action runs, then comes back here until you quit
    while ($true) {
        Section "Your virtual machines"
        Update-Inventory
        Write-Host ""
        Write-Host "   What would you like to do?"
        Write-Host "     [1] Create a new Ubuntu VM (default)"
        Write-Host "     [2] Rename a VM"
        Write-Host "     [3] Delete VMs, folders or ISOs"
        Write-Host "     [4] Doctor: check the health of your VMs"
        Write-Host "     [q] Quit"
        $mode = (Ask "Choice (1-4 or q)").Trim().ToLower(); if (-not $mode) { $mode = '1' }
        if ($mode -in 'q', 'quit', 'exit') { break }
        elseif ($mode -eq '1') { Invoke-Create }
        elseif ($mode -eq '2') { Section "Rename a VM"; Invoke-Rename }
        elseif ($mode -eq '3') { Section "Delete VMs, folders or ISOs"; Invoke-Delete }
        elseif ($mode -eq '4') { Section "Doctor: health check"; Invoke-Doctor }
        else { Warn "Pick one of the numbers shown, or q to quit." }
    }
    Write-Host ""; OK "Bye."
}
catch {
    Write-Log ""; Write-Log ("STOPPED: " + $_.Exception.Message)
    throw
}
finally {
    if ($script:LogPath) { Microsoft.PowerShell.Utility\Write-Host "`nA log of this run (names and password masked) was saved to $($script:LogPath)" -ForegroundColor DarkGray }
}
