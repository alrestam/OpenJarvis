# ── OpenJarvis: fix `uv sync` "Access is denied" on Windows ───────────
# Handles the common causes in order:
#   1. python.exe / uv.exe still holding files in .venv
#   2. .venv locked or owned by another principal
#   3. Windows Defender scanning during install
#   4. Long path limit tripping `anthropic` and friends
#   5. hardlink locks (UV default link mode on same volume)
#   6. OneDrive syncing the project folder
#
# Run from an ordinary PowerShell in the repo root:
#   powershell -ExecutionPolicy Bypass -File .\scripts\fix-uv-sync-windows.ps1
#
# Registry + Defender exclusion steps auto-elevate via a nested elevated
# PowerShell; the rest runs unprivileged. Pass `-SkipRegistry`,
# `-SkipDefender`, or `-NoElevate` to opt out.
# ──────────────────────────────────────────────────────────────────────

[CmdletBinding()]
param(
    [string]$Extra = "server",
    [switch]$SkipRegistry,
    [switch]$SkipDefender,
    [switch]$NoElevate,
    [switch]$KeepVenv
)

$ErrorActionPreference = "Stop"
$repo = (Get-Location).Path

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    $msg" -ForegroundColor Red }

if (-not (Test-Path "pyproject.toml")) {
    Write-Err2 "pyproject.toml not found in $repo — run this from the repo root."
    exit 2
}

# 1) Kill anything still holding the venv open ─────────────────────────
Write-Step "Stopping python/uv processes that may hold .venv files"
$targets = @("python", "pythonw", "python3", "uv", "uvx", "ruff", "pytest")
foreach ($name in $targets) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.Kill()
            Write-Ok "killed $($_.ProcessName) ($($_.Id))"
        } catch {
            Write-Warn2 "could not stop $($_.ProcessName) ($($_.Id)): $($_.Exception.Message)"
        }
    }
}

# 2) Remove .venv with escalation if plain delete fails ────────────────
if (-not $KeepVenv -and (Test-Path ".venv")) {
    Write-Step "Removing existing .venv"
    try {
        Remove-Item -Recurse -Force .venv -ErrorAction Stop
        Write-Ok "removed"
    } catch {
        Write-Warn2 "plain remove failed: $($_.Exception.Message)"
        Write-Warn2 "trying takeown + icacls"
        try {
            & takeown /f .venv /r /d y | Out-Null
            & icacls .venv /grant "$($env:USERNAME):F" /t /c /q | Out-Null
            Remove-Item -Recurse -Force .venv -ErrorAction Stop
            Write-Ok "removed after ownership grab"
        } catch {
            Write-Err2 "still cannot delete .venv — reboot the machine and rerun this script."
            exit 3
        }
    }
}

# 3) Long paths (registry, needs elevation) + Defender exclusion ───────
$needsElevation = (-not $SkipRegistry) -or (-not $SkipDefender)
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($needsElevation -and -not $isAdmin -and -not $NoElevate) {
    Write-Step "Running one elevated PowerShell for LongPaths + Defender exclusion"
    $elevatedScript = @"
`$ErrorActionPreference = 'Continue'
try {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' ``
        -Name 'LongPathsEnabled' -Value 1 -PropertyType DWORD -Force | Out-Null
    Write-Host 'LongPathsEnabled = 1' -ForegroundColor Green
} catch { Write-Host `"LongPaths registry: `$(`$_.Exception.Message)`" -ForegroundColor Yellow }
try {
    Add-MpPreference -ExclusionPath '$repo' -ErrorAction Stop
    Add-MpPreference -ExclusionProcess 'uv.exe' -ErrorAction Stop
    Add-MpPreference -ExclusionProcess 'python.exe' -ErrorAction Stop
    Write-Host 'Defender exclusions added' -ForegroundColor Green
} catch { Write-Host `"Defender: `$(`$_.Exception.Message)`" -ForegroundColor Yellow }
"@
    $tmp = Join-Path $env:TEMP "openjarvis-fix-elevated.ps1"
    Set-Content -Path $tmp -Value $elevatedScript -Encoding UTF8
    try {
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$tmp
        Write-Ok "elevated block finished"
    } catch {
        Write-Warn2 "elevation declined or failed — continuing without it"
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
} elseif ($isAdmin) {
    if (-not $SkipRegistry) {
        Write-Step "Enabling Windows LongPaths"
        try {
            New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
                -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force | Out-Null
            Write-Ok "LongPathsEnabled = 1"
        } catch { Write-Warn2 $_.Exception.Message }
    }
    if (-not $SkipDefender) {
        Write-Step "Adding Windows Defender exclusions"
        try {
            Add-MpPreference -ExclusionPath $repo
            Add-MpPreference -ExclusionProcess "uv.exe"
            Add-MpPreference -ExclusionProcess "python.exe"
            Write-Ok "exclusions added"
        } catch { Write-Warn2 $_.Exception.Message }
    }
}

# git long paths (harmless if already set) ─────────────────────────────
try {
    & git config --global core.longpaths true
    Write-Ok "git core.longpaths = true"
} catch { Write-Warn2 "git config skipped: $($_.Exception.Message)" }

# 4) Warn about OneDrive-synced paths ──────────────────────────────────
Write-Step "Checking whether the project sits inside a OneDrive-synced folder"
$oneDriveRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) `
    | Where-Object { $_ -and (Test-Path $_) }
$inOneDrive = $false
foreach ($od in $oneDriveRoots) {
    if ($repo.StartsWith((Resolve-Path $od).Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        $inOneDrive = $true
        Write-Warn2 "repo is under OneDrive root: $od"
    }
}
if (-not $inOneDrive) {
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    if ($repo.StartsWith($userProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warn2 "repo is under $userProfile — OneDrive commonly syncs this tree."
        Write-Warn2 "if problems continue, move the project to D:\dev\OpenJarvis and re-clone."
    } else {
        Write-Ok "not under a OneDrive root"
    }
}

# 5) Run uv sync with copy link mode to avoid hardlink locks ───────────
Write-Step "Running uv sync --extra $Extra (UV_LINK_MODE=copy)"
$env:UV_LINK_MODE = "copy"
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Err2 "uv is not on PATH — install it from https://astral.sh/uv and rerun."
    exit 4
}

& uv sync --extra $Extra -v
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host ""
    Write-Ok "uv sync succeeded"
    Write-Host "Activate the venv with: .\.venv\Scripts\Activate.ps1"
} else {
    Write-Host ""
    Write-Err2 "uv sync exited with code $code"
    Write-Err2 "if the failing line names a specific file, share it — that pins the root cause."
    exit $code
}
