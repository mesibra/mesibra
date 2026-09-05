param(
    [string]$Port = "COM19",
    [Parameter(Mandatory = $true)][string]$ArtifactUrl
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ExpectedCommit = "61b85d548bc9cce1bec8eaa8f201e8ed3914475f"
$TempRoot = Join-Path $env:TEMP ("CoolSmart-P4-PhoneSetup-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "firmware.zip"
$ExtractRoot = Join-Path $TempRoot "fw"

function Assert-Sha256([string]$Path, [string]$Expected) {
    if (-not (Test-Path $Path)) { throw "Missing firmware file: $Path" }
    $Actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "SHA256 mismatch: $Path`nExpected: $Expected`nActual:   $Actual" }
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null

try {
    Write-Host "[1/7] Checking COM port $Port..." -ForegroundColor Cyan
    $serial = Get-CimInstance Win32_SerialPort | Where-Object { $_.DeviceID -eq $Port }
    if (-not $serial) { throw "Port $Port not found." }

    Write-Host "[2/7] Downloading CI-verified P4 phone-setup firmware..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $ArtifactUrl -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractRoot -Force

    $commitFile = Get-ChildItem -Path $ExtractRoot -Filter "commit.txt" -File -Recurse | Select-Object -First 1
    if (-not $commitFile) { throw "commit.txt not found in firmware package." }
    $FwRoot = $commitFile.Directory.FullName
    $ActualCommit = (Get-Content $commitFile.FullName -Raw).Trim()
    if ($ActualCommit -ne $ExpectedCommit) { throw "Unexpected firmware commit: $ActualCommit" }

    $Boot = Join-Path $FwRoot "bootloader\bootloader.bin"
    $Part = Join-Path $FwRoot "partition_table\partition-table.bin"
    $Ota = Join-Path $FwRoot "ota_data_initial.bin"
    $App = Join-Path $FwRoot "CoolSmartP4Monitor.bin"
    $Storage = Join-Path $FwRoot "storage.bin"

    Assert-Sha256 $Boot    "a342148601142d14056daf3832cf83b101ef9d917e297e61ea8da0636a813971"
    Assert-Sha256 $Part    "3ba490af9dac62e05c22ca5a124018f5fdca958ffd1a767bb90eae7b558400df"
    Assert-Sha256 $Ota     "7d2c7ac4888bfd75cd5f56e8d61f69595121183afc81556c876732fd3782c62f"
    Assert-Sha256 $App     "73b2d0475edcbe760d0d5c574e6edcf2162516a36c60eda43e667b04acb13e52"
    Assert-Sha256 $Storage "c1ec6e89a70576f5f8786c56a834aa6589a2f0bb801d0bd30e76922df17ffec1"
    Write-Host "Firmware commit and SHA256 checks OK." -ForegroundColor Green

    Write-Host "[3/7] Checking esptool..." -ForegroundColor Cyan
    & py -m esptool version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Python/esptool not available." }

    Write-Host "[4/7] Backing up NVS before any write..." -ForegroundColor Cyan
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FactoryBackup = Join-Path $Desktop ("P4-nvsfactory-" + $Stamp + ".bin")
    $NvsBackup = Join-Path $Desktop ("P4-nvs-" + $Stamp + ".bin")

    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x9000 0x32000 $FactoryBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read nvsfactory; flashing stopped." }
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x3b000 0xd2000 $NvsBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read NVS; flashing stopped." }
    Write-Host "NVS backups saved to Desktop." -ForegroundColor Green

    Write-Host "[5/7] Flashing safe explicit offsets. NO erase-flash. NO full.bin." -ForegroundColor Cyan
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 write-flash --flash-mode dio --flash-freq 80m --flash-size 32MB `
        0x2000 $Boot `
        0x110000 $App `
        0x8000 $Part `
        0x10d000 $Ota `
        0xa10000 $Storage
    if ($LASTEXITCODE -ne 0) { throw "Flashing failed with exit code $LASTEXITCODE" }

    Write-Host "[6/7] Phone-setup firmware 61b85d5 flashed successfully." -ForegroundColor Green
    Write-Host "[7/7] Opening serial console at 2,000,000 baud. Press Ctrl+] to exit." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    & py -m serial.tools.miniterm $Port 2000000
}
finally {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
