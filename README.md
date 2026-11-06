# ubuntu-vm-setup

A guided PowerShell script that sets up a clean Ubuntu Desktop virtual machine on Windows.
It detects the best hypervisor on your machine, downloads and verifies the latest Ubuntu LTS,
installs it unattended, and saves a clean snapshot you can reset to.

It is built to be followed by anyone, with plain-language steps, sensible defaults you can
accept or customize, and a clear summary before it builds anything.

## What it does

- Detects the right hypervisor automatically:
  - **Hyper-V** when it is available (native speed).
  - **VirtualBox** when there is no hypervisor (for example, Windows Home). Installs or
    updates VirtualBox for you if needed.
- Finds and downloads the **latest Ubuntu LTS Desktop** ISO, and verifies its SHA256 checksum.
- Installs Ubuntu **unattended** (on Hyper-V you confirm the automated install once).
- Creates the VM with your chosen memory, CPUs, and disk, and a login account you set.
- Takes a **clean snapshot/checkpoint** at the end so you can always roll back.
- Logs the whole run to `VMs\setup-log-<timestamp>.txt`, with VM names, the login username
  and the password replaced by placeholders (`<vm-1>`, `<user>`, `<password>`), so the log is
  safe to share when asking for help.

### If the name is already taken

The script checks the name against **both** Hyper-V and VirtualBox, and against the folder
`VMs\<name>` (both hypervisors use that same folder). If anything is there, it lists exactly
what replacing would delete, and you choose:

- **[r] Replace**: the old VM, its disks and the folder are deleted, then the new VM is built.
  This happens only after the new Ubuntu ISO is downloaded and verified, so a failed download
  never costs you the old VM.
- **[n] Change the name**: nothing is touched; type another name.

## Requirements

- Windows 10 or 11.
- **PowerShell run as Administrator** (needed to create VMs and install software).
- Hyper-V requires Windows **Pro, Enterprise, or Education**. On Windows **Home**, the script
  uses VirtualBox instead.
- About **60 GB** of free disk space for the download and the VM.
- CPU virtualization enabled in your BIOS/UEFI (check Task Manager > Performance > CPU >
  "Virtualization: Enabled").
- An internet connection.

## How to run

1. Download `setup-ubuntu-vm.ps1`.
2. Open **PowerShell as Administrator** and go to the folder with the script:
   ```powershell
   cd $env:USERPROFILE\Downloads
   ```
3. Allow scripts for this session only (resets when you close the window):
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   ```
4. If Windows flagged the file as downloaded, unblock it once:
   ```powershell
   Unblock-File .\setup-ubuntu-vm.ps1
   ```
5. Run it and follow the prompts:
   ```powershell
   .\setup-ubuntu-vm.ps1
   ```

The whole thing takes about 20 to 40 minutes, most of it the download and install. You can
step away once it starts.

## Options

You can change any default without editing the file:

```powershell
.\setup-ubuntu-vm.ps1 -VMName ubuntu-test -Username dev -MemoryMB 8192 -Cpus 4 -DiskGB 50
```

| Option           | Default            | Notes                                               |
|------------------|--------------------|-----------------------------------------------------|
| `-VMName`        | `ubuntu-dev`       | Name of the VM.                                     |
| `-UbuntuVersion` | `lts`              | `lts`, `latest`, or an exact version like `24.04`.  |
| `-Username`      | `dev`              | Linux login username.                               |
| `-MemoryMB`      | `8192`             | RAM in MB. Auto-capped to fit your host.            |
| `-Cpus`          | `4`                | CPU cores. Auto-capped to fit your host.            |
| `-DiskGB`        | `50`              | Virtual disk size. Grows as needed.                 |
| `-TimeZone`      | `Europe/Lisbon`    | VM time zone.                                        |
| `-WorkDir`       | `%USERPROFILE%\VMs`| Where ISOs and VMs are stored.                      |
| `-DryRun`        | off                | Rehearse: walk every prompt, change nothing.        |

You set the password at a prompt when the script runs; it is never stored in the file.

### Rehearse first with `-DryRun`

```powershell
.\setup-ubuntu-vm.ps1 -DryRun
```

This walks the whole wizard (checks, the name and any clash, settings, account, summary)
and then, instead of asking "Start the build?", prints exactly what it *would* do, including
anything a replace would delete. Nothing is created, deleted, converted or downloaded; only
a `setup-log-*-dryrun.txt` log is written. It runs without Administrator too, but then
Hyper-V VMs are invisible to it, so run it elevated to check name clashes against Hyper-V.

## After it finishes

- **Hyper-V:** open **Hyper-V Manager** and double-click your VM (or run
  `vmconnect localhost <name>`). Keep "Enhanced session" on for a full-size desktop and
  clipboard sharing.
- **VirtualBox:** the VM opens automatically and is listed in the VirtualBox app.
- Log in with the username and password you set.
- Reset to the clean install anytime:
  - Hyper-V: `Restore-VMCheckpoint -VMName <name> -Name clean -Confirm:$false`
  - VirtualBox: `VBoxManage snapshot <name> restore clean`

## Tested so far

The Hyper-V path is the main one and is being tested first. The VirtualBox path (for PCs with
no hypervisor, such as Windows Home) has had less testing.

## A note on speed (Hyper-V vs VirtualBox)

If a hypervisor is active on your machine (for example, because Hyper-V, WSL, or
Virtualization-Based Security is on), **VirtualBox runs slowly on top of it**, and the script
will tell you. On such machines the fast path is Hyper-V. If Hyper-V is off but a hypervisor is
forced on, enable Hyper-V and reboot for full speed:

```powershell
dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart
```

## License

MIT. See `LICENSE`.

---

## Repo metadata (for maintainers)

When making the repo public, set these in the repo's **About** box.

**Description:**

> Guided PowerShell wizard to create a clean Ubuntu Desktop VM on Windows, auto-detecting Hyper-V or VirtualBox, with unattended install and a clean snapshot.

**Topics:**

`powershell` `windows` `ubuntu` `hyper-v` `virtualbox` `vm` `virtual-machine` `automation` `autoinstall` `cloud-init` `devops` `wizard`
