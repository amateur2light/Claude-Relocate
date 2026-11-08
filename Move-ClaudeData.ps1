<#
.SYNOPSIS
    Moves the Claude desktop app data (%APPDATA%\Claude) to another drive/folder
    and leaves a junction in its place, so Claude keeps working normally.

.DESCRIPTION
    Steps performed:
      1. Validates the source, the destination and free space.
      2. Closes all running Claude processes.
      3. Copies the data with robocopy and verifies the copy.
      4. Renames the original folder to Claude.bak (backup).
      5. Creates a junction %APPDATA%\Claude -> <Destination>\AppData-Claude.
      6. Clears Chromium/Electron caches (prevents the blank-screen issue).
      7. Lets you test Claude, then optionally deletes the backup.

    Use -Rollback to undo the move and put the data back on C:.

.PARAMETER Destination
    Base folder to move the data into, e.g. D:\Apps\Claude or E:\Claude.
    Data is placed in <Destination>\AppData-Claude.
    If omitted, you will be prompted for it.

.PARAMETER KeepBackup
    Do not offer to delete the Claude.bak backup at the end.

.PARAMETER Rollback
    Undo a previous move: removes the junction and restores the data to
    %APPDATA%\Claude (from Claude.bak if present, otherwise copied back
    from the destination).

.PARAMETER Help
    Show this help. Also works as -h, --help or /?.

.EXAMPLE
    .\Move-ClaudeData.ps1 --help
    .\Move-ClaudeData.ps1
    .\Move-ClaudeData.ps1 -Destination "E:\Claude"
    .\Move-ClaudeData.ps1 -Destination "D:\AppData\Claude" -KeepBackup
    .\Move-ClaudeData.ps1 -Rollback -Destination "E:\Claude"

.NOTES
    Run from PowerShell (Windows PowerShell 5.1 or PowerShell 7).
    If scripts are blocked:
      powershell -ExecutionPolicy Bypass -File .\Move-ClaudeData.ps1
#>

[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$KeepBackup,
    [switch]$Rollback,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Support -Help, -h, --help, /?, help (PowerShell passes "--help" as a plain string)
if ($Help -or $Destination -in @('--help', '-help', '/?', '/h', 'help', '-?')) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

# ---------- helpers ----------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!]  $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "`n[ERROR] $msg" -ForegroundColor Red; exit 1 }

function Get-FolderSize($path) {
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 } else { return [int64]$sum }
}

function Test-IsJunction($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Stop-Claude {
    $procs = Get-Process -Name '*claude*' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Warn "Closing $($procs.Count) Claude process(es)..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (Get-Process -Name '*claude*' -ErrorAction SilentlyContinue) {
            Fail "Claude is still running. Quit it from the system tray and run the script again."
        }
    }
    Write-Ok "No Claude processes running."
}

function Remove-Junction($path) {
    # rmdir on a junction removes only the link, never the target's contents
    cmd /c rmdir "`"$path`"" | Out-Null
    if (Test-Path -LiteralPath $path) { Fail "Could not remove junction at $path" }
}

function Invoke-Robocopy($from, $to) {
    robocopy "$from" "$to" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH
    $code = $LASTEXITCODE
    # robocopy: 0-7 = success (with various info), 8+ = failure
    if ($code -ge 8) { Fail "robocopy reported failures (exit code $code). Nothing was renamed or linked. Review the output above." }
    Write-Ok "Copy finished (robocopy exit code $code)."
}

function Clear-ClaudeCaches($dataPath) {
    $caches = 'Cache','Code Cache','GPUCache','DawnCache','DawnGraphiteCache',
              'DawnWebGPUCache','Service Worker\CacheStorage'
    foreach ($c in $caches) {
        $p = Join-Path $dataPath $c
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Caches cleared (they rebuild automatically)."
}

function Start-Claude {
    $app = Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Claude' } | Select-Object -First 1
    if ($app) {
        Start-Process "shell:AppsFolder\$($app.AppID)"
        Write-Ok "Claude launched."
    } else {
        Write-Warn "Couldn't find Claude in the Start menu. Please open it manually."
    }
}

# ---------- paths ----------
$Source = Join-Path $env:APPDATA 'Claude'
$Backup = Join-Path $env:APPDATA 'Claude.bak'

if (-not $Destination) {
    $Destination = Read-Host "Enter the destination folder for Claude data (e.g. E:\Claude)"
}
$Destination = $Destination.Trim().Trim('"').TrimEnd('\')
if (-not $Destination) { Fail "No destination given." }

# Junctions only work with local drives, so require a drive-letter path
if ($Destination -notmatch '^[A-Za-z]:\\') {
    Fail "Destination must be a full local path with a drive letter, e.g. E:\Claude (network paths are not supported)."
}
$Destination = [IO.Path]::GetFullPath($Destination)
$Target      = Join-Path $Destination 'AppData-Claude'

$driveRoot = [IO.Path]::GetPathRoot($Destination)
if (-not (Test-Path -LiteralPath $driveRoot)) { Fail "Drive $driveRoot does not exist." }

# ======================================================================
# ROLLBACK
# ======================================================================
if ($Rollback) {
    Write-Step "Rolling back: restoring Claude data to $Source"
    Stop-Claude

    if (Test-IsJunction $Source) {
        Remove-Junction $Source
        Write-Ok "Junction removed."
    } elseif (Test-Path -LiteralPath $Source) {
        Fail "$Source is a normal folder, not a junction. Nothing to roll back."
    }

    if (Test-Path -LiteralPath $Backup) {
        Rename-Item -LiteralPath $Backup -NewName 'Claude'
        Write-Ok "Restored from backup (Claude.bak)."
    } elseif (Test-Path -LiteralPath $Target) {
        Write-Step "No backup found, copying data back from $Target"
        Invoke-Robocopy $Target $Source
    } else {
        Fail "No backup and no data at $Target. Cannot restore."
    }

    Write-Host "`nRollback complete. Data is back in $Source." -ForegroundColor Green
    Write-Host "Data at $Target was left untouched; delete it manually once Claude works." -ForegroundColor Green
    exit 0
}

# ======================================================================
# MOVE
# ======================================================================
Write-Step "Checking current state"

if (Test-IsJunction $Source) {
    $current = (Get-Item -LiteralPath $Source -Force).Target
    Write-Ok "Already moved: $Source is a junction -> $current"
    exit 0
}
if (-not (Test-Path -LiteralPath $Source)) {
    Fail "$Source not found. Is the Claude desktop app installed and opened at least once?"
}
if ($Target.StartsWith($Source, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "Destination cannot be inside $Source."
}
if (Test-Path -LiteralPath $Backup) {
    Fail "A previous backup exists at $Backup. Delete or rename it first, or run with -Rollback."
}
if ((Test-Path -LiteralPath $Target) -and (Get-ChildItem -LiteralPath $Target -Force | Select-Object -First 1)) {
    Fail "$Target already contains files. Choose another destination or empty that folder."
}

$size  = Get-FolderSize $Source
$free  = (New-Object IO.DriveInfo $driveRoot).AvailableFreeSpace
Write-Ok ("Claude data size : {0:N2} GB" -f ($size / 1GB))
Write-Ok ("Free on {0}     : {1:N2} GB" -f $driveRoot.TrimEnd('\'), ($free / 1GB))
if ($free -lt ($size * 1.1)) { Fail "Not enough free space on $driveRoot." }

Write-Host "`n    From: $Source"
Write-Host "    To  : $Target"
$ans = Read-Host "`nProceed? (y/N)"
if ($ans -notmatch '^[Yy]') { Write-Host "Cancelled."; exit 0 }

Write-Step "Closing Claude"
Stop-Claude

Write-Step "Copying data (this can take a few minutes)"
New-Item -ItemType Directory -Path $Target -Force | Out-Null
Invoke-Robocopy $Source $Target

$copied = Get-FolderSize $Target
if ($copied -lt ($size * 0.98)) {
    Fail ("Copied size ({0:N2} GB) is smaller than source ({1:N2} GB). Original left untouched." -f ($copied/1GB), ($size/1GB))
}
Write-Ok "Copy verified."

Write-Step "Backing up original and creating junction"
Rename-Item -LiteralPath $Source -NewName 'Claude.bak'
Write-Ok "Original renamed to Claude.bak"
try {
    New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
} catch {
    Rename-Item -LiteralPath $Backup -NewName 'Claude'
    Fail "Could not create junction ($($_.Exception.Message)). Original restored."
}
if (-not (Test-IsJunction $Source)) { Fail "Junction verification failed." }
Write-Ok "Junction: $Source -> $Target"

Write-Step "Clearing caches"
Clear-ClaudeCaches $Target

Write-Step "Testing"
Start-Claude
Write-Host "    Check that Claude opens normally and your chats/sign-in are there." -ForegroundColor White

if ($KeepBackup) {
    Write-Warn "Backup kept at $Backup. Delete it later to free the space:"
    Write-Host "      Remove-Item `"$Backup`" -Recurse -Force"
} else {
    $ok = Read-Host "`nIs Claude working correctly? Delete the backup to free space on C:? (y/N)"
    if ($ok -match '^[Yy]') {
        Remove-Item -LiteralPath $Backup -Recurse -Force
        Write-Ok ("Backup deleted. Freed about {0:N2} GB on {1}" -f ($size/1GB), ([IO.Path]::GetPathRoot($env:APPDATA)))
    } else {
        Write-Warn "Backup kept at $Backup."
        Write-Host "    If Claude is broken, undo with:  .\Move-ClaudeData.ps1 -Rollback -Destination `"$Destination`""
    }
}

Write-Host "`nDone. Claude data now lives in $Target" -ForegroundColor Green