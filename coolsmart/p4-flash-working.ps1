param(
    [string]$Port = "COM19"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ArtifactUrl = "https://sdmntprdenmarkeast.oaiusercontent.com/files/00000000-0674-8210-8c6a-ccb7f1620c86/raw?se=2026-09-05T13%3A10%3A51Z&sp=r&sv=2026-02-06&sr=b&scid=a31ef1ef-435c-5fa6-be89-f720f867210a&skoid=9b41a688-1b44-4731-856e-b0efcf3660ed&sktid=a48cca56-e6da-484e-a814-9c849652bcb3&skt=2026-09-05T09%3A11%3A49Z&ske=2026-09-06T09%3A11%3A49Z&sks=b&skv=2026-02-06&sig=DtcMSLioodVb4aY0McOFH/lDCzBN3w4XZAcXWveRKgY%3D"
$ExpectedZipSha256 = "f6af06f29140028e3db58b9e7ffd365f2823943e2989b3b6c7c7919871d2aef1"
$TempRoot = Join-Path $env:TEMP ("CoolSmart-P4-" + [guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempRoot "firmware.zip"
$ExtractPath = Join-Path $TempRoot "fw"

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null

try {
    Write-Host "[1/6] Checking COM port $Port..." -ForegroundColor Cyan
    $serial = Get-CimInstance Win32_SerialPort | Where-Object { $_.DeviceID -eq $Port }
    if (-not $serial) { throw "Port $Port not found." }

    Write-Host "[2/6] Downloading verified working firmware..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $ArtifactUrl -OutFile $ZipPath

    $zipHash = (Get-FileHash -Algorithm SHA256 $ZipPath).Hash.ToLowerInvariant()
    if ($zipHash -ne $ExpectedZipSha256) {
        throw "Firmware ZIP SHA256 mismatch. Expected $ExpectedZipSha256, got $zipHash"
    }

    Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

    $Boot = Join-Path $ExtractPath "bootloader\bootloader.bin"
    $Part = Join-Path $ExtractPath "partition_table\partition-table.bin"
    $Ota = Join-Path $ExtractPath "ota_data_initial.bin"
    $App = Join-Path $ExtractPath "CoolSmartP4Monitor.bin"
    $Storage = Join-Path $ExtractPath "storage.bin"
    foreach ($f in @($Boot,$Part,$Ota,$App,$Storage)) {
        if (-not (Test-Path $f)) { throw "Missing firmware file: $f" }
    }

    Write-Host "[3/6] Backing up current nvsfactory before any write..." -ForegroundColor Cyan
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $BackupPath = Join-Path $Desktop ("P4-nvsfactory-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bin")
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x9000 0x32000 $BackupPath
    if ($LASTEXITCODE -ne 0) { throw "Could not read nvsfactory; flashing stopped." }

    $factoryBytes = [System.IO.File]::ReadAllBytes($BackupPath)
    $nonFF = 0
    foreach ($b in $factoryBytes) { if ($b -ne 0xFF) { $nonFF++; if ($nonFF -ge 16) { break } } }
    if ($nonFF -eq 0) {
        Write-Host "WARNING: nvsfactory is already erased (all FF). Previous full.bin write likely erased factory data." -ForegroundColor Red
        Write-Host "A backup of the current erased region was still saved to: $BackupPath" -ForegroundColor Yellow
    } else {
        Write-Host "nvsfactory contains data and was backed up safely to: $BackupPath" -ForegroundColor Green
    }

    Write-Host "[4/6] Flashing ONLY valid partitions. nvsfactory/nvs are NOT touched..." -ForegroundColor Cyan
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 write-flash --flash-mode dio --flash-freq 80m --flash-size 32MB `
        0x2000 $Boot `
        0x8000 $Part `
        0x10d000 $Ota `
        0x110000 $App `
        0xa10000 $Storage
    if ($LASTEXITCODE -ne 0) { throw "Flashing failed with exit code $LASTEXITCODE" }

    Write-Host "[5/6] Flash completed and verified." -ForegroundColor Green
    Write-Host "[6/6] Opening 2,000,000 baud monitor. Press Ctrl+] to exit." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    & py -m serial.tools.miniterm $Port 2000000
}
finally {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
