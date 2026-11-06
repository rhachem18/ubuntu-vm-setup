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
  VMs\setup-log-*.txt. Hyper-V also offers migrating a VirtualBox VM and cleanup.

.NOTES
  RUN (PowerShell as Administrator):
     cd $env:USERPROFILE\Downloads
     Set-ExecutionPolicy -Scope Process Bypass
     Unblock-File .\setup-ubuntu-vm.ps1
     .\setup-ubuntu-vm.ps1
  Override any default up front:  .\setup-ubuntu-vm.ps1 -VMName ubuntu-test -MemoryMB 8192
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
    [string]$WorkDir       = "$env:USERPROFILE\VMs"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
        $in = Read-Host "VM name [$default]"
        if ($in) { $default = $in.Trim() }
        $ok = $default -match '^[A-Za-z0-9._-]+$'
        if (-not $ok) { Warn "Letters, digits, dot, dash or underscore only." }
    } until ($ok)
    return $default
}
function Prompt-Account($defaultUser) {
    do {
        $in = Read-Host "Login username [$defaultUser]"
        if ($in) { $defaultUser = $in.Trim() }
        $ok = $defaultUser -match '^[a-z][a-z0-9_-]*$'
        if (-not $ok) { Warn "Lowercase, start with a letter." }
    } until ($ok)
    do {
        $p1 = Read-Host "Choose a password" -AsSecureString
        $p2 = Read-Host "Confirm password" -AsSecureString
        $pw1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $pw2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        $bad = ':"''`\'.ToCharArray()
        $hasBad = ($pw1.IndexOfAny($bad) -ge 0) -or ($pw1 -match "[\r\n]")
        $ok = ($pw1 -eq $pw2) -and ($pw1.Length -ge 4) -and (-not $hasBad)
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
        $info = & $vbManage showvminfo $name --machinereadable 2>$null
        if ($LASTEXITCODE -eq 0 -and $info) {
            $mem = 0; $cpu = 0
            foreach ($l in $info) { if ($l -match '^memory=(\d+)') { $mem = [int]$Matches[1] }; if ($l -match '^cpus=(\d+)') { $cpu = [int]$Matches[1] } }
            if ($mem -gt 0) { return [pscustomobject]@{ Found = $true; Where = 'VirtualBox'; Mem = $mem; Cpu = $cpu; Disk = $null } }
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
        $in = (Read-Host ("$prompt [$default]")).Trim()
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
    $pick = (Read-Host "Choice ($choices)").Trim().ToLower()
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
        $verIn = (Read-Host "Ubuntu version: lts / latest / a number like 24.04 [$defVer]").Trim()
        if (-not $verIn) { $verIn = $defVer }
        return [pscustomobject]@{ Mem = $mem; Cpu = $cpu; Disk = $disk; Ver = $verIn }
    }
    return [pscustomobject]@{ Mem = $recMem; Cpu = $recCpu; Disk = $defDisk; Ver = $defVer }
}
function Show-Summary($osText, $target, $mem, $hostRam, $cpu, $hostCpu, $disk, $user, $name, $replaces, $replacesWhere) {
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
    Write-Host ""
    Write-Host "  This takes about 20 to 40 minutes. You can step away once it starts."
    Write-Host $Rule -ForegroundColor Green
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
        $vms = & $vbManage list vms 2>$null
        if ($vms -match "`"$name`"") {
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
function Migrate-VBox($src, $vbManage, $WorkDir, $switchName, $MemoryMB, $Cpus) {
    $newName = "$src-hv"
    if (Get-VM -Name $newName -ErrorAction SilentlyContinue) { throw "A Hyper-V VM '$newName' already exists. Delete it first." }
    $vdi = Get-ChildItem (Join-Path $WorkDir "$src\*.vdi") -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vdi) { throw "Could not find the disk (.vdi) for '$src' under $WorkDir\$src." }
    $script:StepNo = 0; $script:StepTotal = 3
    Step "Converting '$src' disk to Hyper-V format"
    Native { & $vbManage controlvm $src poweroff } | Out-Null; Start-Sleep -Seconds 3
    $newDir = Join-Path $WorkDir $newName; New-Item -ItemType Directory -Force -Path $newDir | Out-Null
    $vhd = Join-Path $newDir "$newName.vhd"; $vhdx = Join-Path $newDir "$newName.vhdx"
    Info "Cloning the .vdi to .vhd (several minutes)..."
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $vbManage clonemedium disk $vdi.FullName $vhd --format VHD
    $rc = $LASTEXITCODE; $ErrorActionPreference = $prev
    if ($rc -ne 0 -or -not (Test-Path $vhd)) { throw "Disk clone failed." }
    Info "Converting .vhd to .vhdx..."
    Convert-VHD -Path $vhd -DestinationPath $vhdx -VHDType Dynamic
    Remove-Item $vhd -Force -ErrorAction SilentlyContinue; Native { & $vbManage closemedium disk $vhd } | Out-Null
    OK "Disk converted."
    Step "Creating the Hyper-V VM '$newName'"
    New-VM -Name $newName -Generation 2 -MemoryStartupBytes ($MemoryMB*1MB) -VHDPath $vhdx -SwitchName $switchName -Path $WorkDir | Out-Null
    Set-VM -Name $newName -StaticMemory -ErrorAction SilentlyContinue
    Set-VMProcessor -VMName $newName -Count $Cpus
    Set-VMFirmware -VMName $newName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
    Set-VMFirmware -VMName $newName -FirstBootDevice (Get-VMHardDiskDrive -VMName $newName | Select-Object -First 1)
    Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction SilentlyContinue
    OK "VM created. Original VirtualBox VM '$src' left untouched."
    Step "Snapshot and open"
    Checkpoint-VM -Name $newName -SnapshotName "clean" -ErrorAction SilentlyContinue
    Start-VM -Name $newName | Out-Null; try { vmconnect.exe localhost $newName } catch {}
    Write-Host ""; Write-Host $Rule -ForegroundColor Green; Write-Host "  MIGRATION DONE" -ForegroundColor Green; Write-Host $Rule -ForegroundColor Green
    OK "'$newName' is running on Hyper-V with a 'clean' checkpoint. Original '$src' is unchanged."
    Warn "If it fails to boot, tell me. The fix is quick and your original is safe."
}
function Remove-OldItems($WorkDir, $vbManage, $hvVMs, $vbVMs, $isos) {
    Write-Host "   What to delete?"
    Write-Host "     [i] ISO files only (frees space, forces re-download next time)"
    Write-Host "     [v] A specific VM by name"
    Write-Host "     [a] EVERYTHING under $WorkDir (all VMs + ISOs, keeps logs)"
    Write-Host "     [n] Nothing, continue"
    $d = (Read-Host "Choice (i/v/a/n)").Trim().ToLower()
    switch ($d) {
        'i' { foreach ($i in $isos) { Remove-Item $i.FullName -Force -ErrorAction SilentlyContinue; Info "Deleted $($i.Name)" } }
        'v' {
            $name = (Read-Host "VM name to delete").Trim()
            if ($hvVMs -contains $name) { Stop-VM $name -TurnOff -Force -ErrorAction SilentlyContinue; Remove-VM $name -Force -ErrorAction SilentlyContinue; Info "Removed Hyper-V VM $name" }
            if ($vbManage -and ($vbVMs -contains $name)) { Native { & $vbManage controlvm $name poweroff } | Out-Null; Native { & $vbManage unregistervm $name --delete } | Out-Null; Info "Removed VirtualBox VM $name" }
            $dir = Join-Path $WorkDir $name; if (Test-Path $dir) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue; Info "Removed folder $name" }
        }
        'a' {
            Warn "This permanently deletes ALL VMs and ISOs under $WorkDir."
            if ((Read-Host "Type 'yes' to confirm") -ne 'yes') { Info "Skipped."; return }
            foreach ($n in $hvVMs) { Stop-VM $n -TurnOff -Force -ErrorAction SilentlyContinue; Remove-VM $n -Force -ErrorAction SilentlyContinue }
            if ($vbManage) { foreach ($n in $vbVMs) { Native { & $vbManage controlvm $n poweroff } | Out-Null; Native { & $vbManage unregistervm $n --delete } | Out-Null } }
            Get-ChildItem $WorkDir -Exclude "setup-log-*.txt" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Info "Deleted all VMs and ISOs (kept logs)."
        }
        default { Info "Nothing deleted." }
    }
}

# ======================================================================= START
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Please run PowerShell as Administrator, then run this again." }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$logPath = Join-Path $WorkDir ("setup-log-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
try { Start-Transcript -Path $logPath -Append | Out-Null; $transcriptOn = $true } catch { $transcriptOn = $false }

$hasHyperVCmdlets = [bool](Get-Command New-VM -ErrorAction SilentlyContinue) -and [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
$hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
$hvFeatureOn = $hvFeature -and ("$($hvFeature.State)" -eq 'Enabled')
$cs = Get-CimInstance Win32_ComputerSystem
$hypervisorOn = [bool]$cs.HypervisorPresent
$hvEnabled = $hasHyperVCmdlets -and ($hvFeatureOn -or $hypervisorOn)
$hostRamMB = [int]($cs.TotalPhysicalMemory / 1MB); $hostCpus = [int]$cs.NumberOfLogicalProcessors
$target = if ($hvEnabled) { "Hyper-V (fast on this PC)" } else { "VirtualBox" }

try {
    Section "Welcome - let's set up an Ubuntu virtual machine"
    Info "This PC: $([math]::Round($hostRamMB/1024,1)) GB RAM, $hostCpus CPUs"
    Info "Will build on: $target"

    if (-not $hvEnabled -and $hypervisorOn) {
        Write-Host ""
        Warn "A hypervisor (likely VBS/Credential Guard) is on but Hyper-V is off, so VirtualBox will be slow here."
        Warn "For full speed, enable Hyper-V (one reboot) then rerun:"
        Write-Host "     dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart"
        if ((Read-Host "Continue now with VirtualBox (slower)? (y/n)") -notmatch '^(y|yes)$') { throw "Stopped. Enable Hyper-V, reboot, then rerun." }
    }

    # ---- checks
    Section "Checking your machine"
    $dl = (Split-Path -Qualifier $WorkDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $dl).Free / 1GB, 1)
    $isoP = [bool](Get-ChildItem (Join-Path $WorkDir "ubuntu-*-desktop-amd64.iso") -ErrorAction SilentlyContinue)
    $needGB = if ($isoP) { 12 } else { 20 }
    if ($freeGB -lt $needGB) { throw "Only $freeGB GB free on ${dl}:. Please free about $needGB GB and rerun." }
    OK "Free space on ${dl}: $freeGB GB"
    try { Invoke-WebRequest "https://releases.ubuntu.com/" -UseBasicParsing -TimeoutSec 15 -Method Head | Out-Null } catch { try { Invoke-WebRequest "https://releases.ubuntu.com/" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { throw "No internet connection to releases.ubuntu.com. Check your connection and rerun." } }
    OK "Internet connection OK"

    # ---- inventory + what to do
    Section "Your existing virtual machines"
    $vbManage = Get-VBoxManage
    $hvVMs = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $vbVMs = @(); if ($vbManage) { $vbVMs = @((& $vbManage list vms) | ForEach-Object { if ($_ -match '^"([^"]+)"') { $Matches[1] } }) }
    $isos = @(Get-ChildItem (Join-Path $WorkDir "ubuntu-*.iso") -ErrorAction SilentlyContinue)
    if ($hvVMs) { Info ("Hyper-V VMs: " + ($hvVMs -join ', ')) } else { Info "Hyper-V VMs: none" }
    if ($vbVMs) { Info ("VirtualBox VMs: " + ($vbVMs -join ', ')) } else { Info "VirtualBox VMs: none" }
    if ($isos) { foreach ($i in $isos) { Info ("Saved ISO: {0} ({1:N0} MB)" -f $i.Name, ($i.Length/1MB)) } } else { Info "Saved ISOs: none" }
    Write-Host ""
    Write-Host "   What would you like to do?"
    Write-Host "     [c] Create a new Ubuntu VM (default)"
    $canMigrate = $hvEnabled -and $vbVMs
    if ($canMigrate) { Write-Host "     [m] Move a VirtualBox VM onto Hyper-V (keeps the original)" }
    Write-Host "     [d] Delete old VMs or ISOs first"
    $mode = (Read-Host "Choice (c$(if($canMigrate){'/m'})/d)").Trim().ToLower(); if (-not $mode) { $mode = 'c' }

    if ($mode -eq 'm' -and $canMigrate) {
        Write-Host "   VirtualBox VMs you can move:"
        for ($k = 0; $k -lt $vbVMs.Count; $k++) { Write-Host ("     [{0}] {1}" -f ($k+1), $vbVMs[$k]) }
        $src = $null
        do {
            $pk = (Read-Host "Enter the number or exact name").Trim()
            if ($pk -match '^\d+$' -and [int]$pk -ge 1 -and [int]$pk -le $vbVMs.Count) { $src = $vbVMs[[int]$pk-1] }
            elseif ($vbVMs -contains $pk) { $src = $pk } else { Warn "Enter a number from the list or the exact name." }
        } until ($src)
        Migrate-VBox $src $vbManage $WorkDir (Ensure-Switch) $MemoryMB $Cpus
        return
    }
    if ($mode -eq 'd') { Section "Delete old items"; Remove-OldItems $WorkDir $vbManage $hvVMs $vbVMs $isos }

    # ---- name
    Section "Name your VM"
    $VMName = Prompt-VMName $VMName
    $existing = Get-ExistingVMSettings $VMName $hvEnabled $vbManage
    while ($existing.Found) {
        $buildingOn = if ($hvEnabled) { 'Hyper-V' } else { 'VirtualBox' }
        Warn "A VM named '$VMName' already exists in $($existing.Where)."
        if ($existing.Where -ne $buildingOn) {
            Warn "You're building on $buildingOn, and both use the folder VMs\$VMName, so replacing will DELETE the $($existing.Where) VM and its disk."
            if ($existing.Where -eq 'VirtualBox' -and $hvEnabled) { Write-Host "     (To keep it, cancel and rerun, then choose [m] to move it to Hyper-V instead.)" }
        }
        Write-Host "     [r] Replace it (deletes the $($existing.Where) VM '$VMName')"
        Write-Host "     [n] Pick a different name (keeps it)"
        $clash = (Read-Host "Choice (r/n)").Trim().ToLower()
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
    Show-Summary $osText $target $MemoryMB $hostRamMB $Cpus $hostCpus $DiskGB $Username $VMName $replaces $replacesWhere
    if ((Read-Host "Start the build? (y/n)") -notmatch '^(y|yes)$') { throw "No problem, stopped before building. Rerun whenever you're ready." }

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
        function VBox { $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $out = & $VBoxManage @args 2>&1 } finally { $ErrorActionPreference = $prevEAP }; foreach ($line in $out) { $t = "$line".Trim(); if ($t) { Write-Host "     $t" -ForegroundColor DarkGray } }; if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args[0]) failed (exit $LASTEXITCODE)." } }
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
        do { Start-Sleep -Seconds 15; $ga = & $VBoxManage guestproperty get $VMName "/VirtualBox/GuestAdd/Version" 2>$null; $w = (Get-Width) - 1; $ln = ("  {0:hh\:mm\:ss} elapsed" -f ((Get-Date)-$start)); Write-Host ("`r" + $ln.PadRight($w)) -NoNewline; if ($ga -match '^Value:') { $installed = $true; break } } while ((Get-Date) -lt $deadline)
        Write-Host ""
        if (-not $installed) { throw "Install did not complete within 90 minutes. Check the VM window." }
        OK "Ubuntu installed."

        Step "Saving a clean snapshot"
        VBox storageattach $VMName --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
        VBox controlvm $VMName acpipowerbutton
        $deadline = (Get-Date).AddMinutes(5)
        do { Start-Sleep -Seconds 5; $info = & $VBoxManage showvminfo $VMName --machinereadable 2>$null; $state = ($info | Select-String '^VMState=' | Select-Object -First 1).ToString(); if ((Get-Date) -gt $deadline) { VBox controlvm $VMName poweroff } } until ($state -match 'poweroff')
        VBox snapshot $VMName take clean --description "Clean Ubuntu install"
        VBox startvm $VMName --type gui

        Write-Host ""; Write-Host $Rule -ForegroundColor Green; Write-Host "  ALL DONE" -ForegroundColor Green; Write-Host $Rule -ForegroundColor Green
        OK "'$VMName' (Ubuntu $UbuntuVersion) is running on VirtualBox with a 'clean' snapshot."
        OK "Log in with username '$Username' and your password."
        Write-Host "   Reset: & `"$VBoxManage`" snapshot $VMName restore clean"
    }
}
finally {
    if ($transcriptOn) { try { Stop-Transcript | Out-Null; Write-Host "`nA log of this run was saved to $logPath" -ForegroundColor DarkGray } catch {} }
}
