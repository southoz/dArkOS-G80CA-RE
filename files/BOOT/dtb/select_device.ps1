#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$host.UI.RawUI.WindowTitle = "R36S / Clone / Soysauce DTB + Logo Selector"

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "   R36S DTB Firmware + Logo Selector"           -ForegroundColor Cyan
Write-Host "==================================================`n" -ForegroundColor Cyan

# Determine root folder
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ((Split-Path -Leaf $scriptDir) -eq "dtb") {
    $rootDir = Split-Path -Parent $scriptDir
} else {
    $rootDir = $scriptDir
}

Write-Host "Root folder: $rootDir" -ForegroundColor DarkCyan

# Find INI
$iniCandidates = @(
    (Join-Path $rootDir "r36_devices.ini"),
    (Join-Path $rootDir "dtb\r36_devices.ini")
)

$iniPath = $null
foreach ($candidate in $iniCandidates) {
    if (Test-Path $candidate) {
        $iniPath = $candidate
        Write-Host "Using INI: $iniPath" -ForegroundColor Green
        break
    }
}

if (-not $iniPath) {
    Write-Host "ERROR: r36_devices.ini not found" -ForegroundColor Red
    Pause
    exit 1
}

# Parse INI
Write-Host "`nReading devices..." -ForegroundColor Yellow

$sections = [ordered]@{}
$currentSection = $null

Get-Content $iniPath -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '^\[(.+)\]$') {
        $currentSection = $matches[1].Trim()
        $sections[$currentSection] = @{}
    }
    elseif ($currentSection -and $line -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
        $key   = $matches[1].Trim()
        $value = $matches[2].Trim()
        $sections[$currentSection][$key] = $value
    }
}

if ($sections.Count -eq 0) {
    Write-Host "ERROR: No devices found in INI" -ForegroundColor Red
    Pause
    exit 1
}

# Group by variant
$grouped = [ordered]@{}

foreach ($dev in $sections.Keys) {
    $v = $sections[$dev]['variant']
    if (-not $v) { $v = "unknown" }

    if (-not $grouped.Contains($v)) {
        $grouped[$v] = New-Object System.Collections.ArrayList
    }
    $null = $grouped[$v].Add($dev)
}

$variantDisplayOrder = @("r36s", "clone", "soysauce")
$sortedVariants = $variantDisplayOrder | Where-Object { $grouped.Contains($_) }
$sortedVariants += ($grouped.Keys | Where-Object { $_ -notin $variantDisplayOrder })

# Two-column menu
Write-Host "`nAvailable devices:" -ForegroundColor Cyan
Write-Host ""

$globalIndex = 1
$deviceList = @{}   # Device selection lookup

foreach ($variant in $sortedVariants) {
    $devicesInGroup = $grouped[$variant]

    if ($devicesInGroup.Count -eq 0) { continue }

    Write-Host "Variant: $variant" -ForegroundColor Magenta
    Write-Host ("-" * 70) -ForegroundColor DarkGray

    $half = [math]::Ceiling($devicesInGroup.Count / 2)

    for ($row = 0; $row -lt $half; $row++) {
        $leftPart = ""
        $rightPart = ""

        # Left column
        if ($row -lt $devicesInGroup.Count) {
            $num = $globalIndex
            $leftPart = "{0,4}. {1}" -f $num, $devicesInGroup[$row]
            $deviceList[$num] = $devicesInGroup[$row]
            $globalIndex++
        }

        # Right column
        $rightIdx = $row + $half
        if ($rightIdx -lt $devicesInGroup.Count) {
            $num = $globalIndex
            $rightPart = "{0,4}. {1}" -f $num, $devicesInGroup[$rightIdx]
            $deviceList[$num] = $devicesInGroup[$rightIdx]
            $globalIndex++
        }

        Write-Host ("{0,-40}{1}" -f $leftPart, $rightPart)
    }

    Write-Host ""
}

Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host "Total: $($sections.Count) devices" -ForegroundColor Cyan

# Selection
Write-Host "`nSelect number (1-$($sections.Count))" -ForegroundColor Cyan
$rawInput = Read-Host
$selection = $rawInput.Trim()

if ($selection -eq '' -or $selection -notmatch '^\d+$') {
    Write-Host "Please enter a valid number." -ForegroundColor Red
    Pause
    exit 1
}

$selNum = [int]$selection

if ($selNum -lt 1 -or $selNum -gt $sections.Count) {
    Write-Host "Number must be between 1 and $($sections.Count)" -ForegroundColor Red
    Pause
    exit 1
}

$chosen  = $deviceList[$selNum]
$variant = $sections[$chosen]['variant']

Write-Host "`nSelected : $chosen" -ForegroundColor Green
Write-Host "Variant  : $variant" -ForegroundColor Green

# ── Get resolution for logo selection ─────────────────────────────────────
$resolution = ""
if ($sections[$chosen].ContainsKey('resolution')) {
    $resolution = $sections[$chosen]['resolution'].Trim()
}

$logoSrc = $null
if ($resolution -eq "640x480") {
    $logoSrc = Join-Path $rootDir "dtb\logo\logo-640x480.bmp"
    Write-Host "Using 640x480 logo" -ForegroundColor Cyan
} elseif ($resolution -eq "720x720") {
    $logoSrc = Join-Path $rootDir "dtb\logo\logo-720x720.bmp"
    Write-Host "Using 720x720 logo" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: No valid resolution found for $chosen (got: '$resolution'). No logo will be copied." -ForegroundColor Yellow
}

# Build source folder
$sourceFolder = Join-Path $rootDir "dtb\$variant\$chosen"

if (-not (Test-Path $sourceFolder -PathType Container)) {
    Write-Host "ERROR: Folder not found: $sourceFolder" -ForegroundColor Red
    Pause
    exit 1
}

# Preview
Write-Host "`nWill copy DTB files from:" -ForegroundColor Cyan
Write-Host "  $sourceFolder" -ForegroundColor White

if ($logoSrc -and (Test-Path $logoSrc)) {
    Write-Host "`nWill replace logo.bmp with:" -ForegroundColor Cyan
    Write-Host "  $logoSrc to logo.bmp" -ForegroundColor White
}

Write-Host "`n.dtbfiles in root that will be deleted/overwritten:"
$existingDtbs = @(Get-ChildItem -Path $rootDir -File -Filter "*.dtb" -ErrorAction SilentlyContinue)
if ($existingDtbs.Count -eq 0) {
    Write-Host "  (none currently present)"
} else {
    $existingDtbs | ForEach-Object { "  $($_.Name)" }
}

Write-Host ""
$confirm = Read-Host "Proceed with copy + logo update? (Y/N)"
if ($confirm -notmatch '^[Yy]$') {
    Write-Host "Cancelled." -ForegroundColor Yellow
    Pause
    exit 0
}

# === Apply changes (atomic with rollback) ===
# The boot partition must never be left without its .dtb / logo files.
# Strategy: stage the incoming files and a backup of the current ones into a
# temp area, install the new files into root, and only then remove the old
# files they supersede. If any step throws, the backup is restored so the
# device is returned to its previous (bootable) state.
$staging = Join-Path $env:TEMP ("dtb_stage_" + [guid]::NewGuid().ToString("N"))
$backup  = Join-Path $env:TEMP ("dtb_backup_" + [guid]::NewGuid().ToString("N"))
$stagedDtbs = @()

try {
    # 1. Stage the new DTB files (and logo, if any) off the boot volume.
    #    Reading them into a temp dir first means a bad/unreadable source
    #    fails here, before anything on the boot volume is touched.
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -Path "$sourceFolder\*.dtb" -Destination $staging -Force -ErrorAction Stop
    if ($logoSrc -and (Test-Path $logoSrc)) {
        Copy-Item -Path $logoSrc -Destination (Join-Path $staging "logo.bmp") -Force -ErrorAction Stop
    }
    $stagedDtbs = @(Get-ChildItem -Path $staging -Filter "*.dtb" -File)
    if ($stagedDtbs.Count -eq 0) {
        throw "No DTB files found in source folder: $sourceFolder"
    }
    Write-Host "`nStaged $($stagedDtbs.Count) new DTB file(s)." -ForegroundColor Yellow

    # 2. Back up the files currently in root so we can roll back.
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Get-ChildItem -Path $rootDir -Filter "*.dtb" -File -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $backup -Force }
    $rootLogo = Join-Path $rootDir "logo.bmp"
    if (Test-Path $rootLogo) { Copy-Item $rootLogo $backup -Force }

    # 3. Install: copy the staged files over the ones in root.
    Write-Host "`nInstalling new DTB files to root..." -ForegroundColor Yellow
    Copy-Item -Path "$staging\*.dtb" -Destination $rootDir -Force -ErrorAction Stop
    $stagedDtbs | ForEach-Object { Write-Host "  Installed $($_.Name)" }

    if ($logoSrc -and (Test-Path $logoSrc)) {
        Write-Host "`nInstalling logo..." -ForegroundColor Yellow
        Copy-Item -Path (Join-Path $staging "logo.bmp") -Destination $rootLogo -Force -ErrorAction Stop
        Write-Host "  logo.bmp installed (from $resolution resolution)"
    } else {
        Write-Host "  No logo installed (missing source or unknown resolution)" -ForegroundColor Yellow
    }

    # 4. Remove old .dtb files that the new set did not replace. Extra .dtb
    #    files are harmless to the bootloader, but we tidy them up for parity
    #    with the previous behaviour. Only now, after a successful install, is
    #    it safe to delete them.
    Write-Host "`nRemoving superseded .dtb files..." -ForegroundColor Yellow
    $keep = $stagedDtbs.Name
    $superseded = @(Get-ChildItem -Path $rootDir -Filter "*.dtb" -File |
                    Where-Object { $_.Name -notin $keep })
    if ($superseded.Count -eq 0) {
        Write-Host "  (no superseded files to remove)"
    } else {
        $superseded | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed $($_.Name)"
        }
    }

    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $backup  -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    # Rollback: restore the backed-up files so the device still boots.
    Write-Host "`nERROR during update - rolling back." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path $backup) {
        # Restore the original files, then discard any new files the failed
        # install already wrote, so root matches its pre-update state exactly.
        # Each step is best-effort so one locked file can't abort the rollback.
        Get-ChildItem -Path $backup -File | ForEach-Object {
            try { Copy-Item $_.FullName $rootDir -Force -ErrorAction Stop } catch { }
        }
        $origNames = (Get-ChildItem -Path $backup -File).Name
        Get-ChildItem -Path $rootDir -Filter "*.dtb" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $origNames } |
            ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
        if ((-not (Test-Path (Join-Path $backup "logo.bmp"))) -and (Test-Path (Join-Path $rootDir "logo.bmp"))) {
            try { Remove-Item (Join-Path $rootDir "logo.bmp") -Force -ErrorAction Stop } catch { }
        }
        Write-Host "Previous files restored from backup." -ForegroundColor Yellow
    }
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $backup  -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Boot volume returned to its prior state. No changes applied." -ForegroundColor Red
    exit 1
}

Write-Host "`n==================================================" -ForegroundColor Green
Write-Host "   SUCCESS - DTB + Logo updated for:"           -ForegroundColor Green
Write-Host "   $chosen"                                     -ForegroundColor White
Write-Host "   Variant: $variant"                           -ForegroundColor White
Write-Host "   Resolution: $resolution"                     -ForegroundColor White
Write-Host "==================================================`n" -ForegroundColor Green
