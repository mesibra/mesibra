param(
    [string]$Port = "COM19"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ArtifactUrl = "https://sdmntprnortheu.oaiusercontent.com/files/00000000-5474-81f4-b453-542b153ad076/raw?se=2026-09-05T13%3A18%3A09Z&sp=r&sv=2026-02-06&sr=b&scid=41c35ccc-6992-536d-922e-0acd733bd800&skoid=9b41a688-1b44-4731-856e-b0efcf3660ed&sktid=a48cca56-e6da-484e-a814-9c849652bcb3&skt=2026-09-05T10%3A34%3A33Z&ske=2026-09-06T10%3A34%3A33Z&sks=b&skv=2026-02-06&sig=uftiW4BKCIngTlj4iwniN%2BUSvfAD212Z6xDtLuD5Cqw%3D"
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

    Write-Host "[3/6] Backing up current NVS regions before any write..." -ForegroundColor Cyan
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FactoryBackup = Join-Path $Desktop ("P4-nvsfactory-" + $Stamp + ".bin")
    $NvsBackup = Join-Path $Desktop ("P4-nvs-" + $Stamp + ".bin")

    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x9000 0x32000 $FactoryBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read nvsfactory; flashing stopped." }
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x3b000 0xd2000 $NvsBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read NVS; flashing stopped." }

    $factoryBytes = [System.IO.File]::ReadAllBytes($FactoryBackup)
    $factoryHasData = $false
    foreach ($b in $factoryBytes) {
        if ($b -ne 0xFF) { $factoryHasData = $true; break }
    }
    if ($factoryHasData) {
        Write-Host "nvsfactory has data; backup saved to $FactoryBackup" -ForegroundColor Green
    } else {
        Write-Host "nvsfactory is blank (all FF). This build has no nvsfactory image in flash_args; continuing safely." -ForegroundColor Yellow
    }
    Write-Host "NVS backup saved to $NvsBackup" -ForegroundColor Green

    Write-Host "[4/6] Flashing EXACT official flash_args offsets. No full.bin and no erase-flash..." -ForegroundColor Cyan
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 write-flash --flash-mode dio --flash-freq 80m --flash-size 32MB `
        0x2000 $Boot `
        0x110000 $App `
        0x8000 $Part `
        0x10d000 $Ota `
        0xa10000 $Storage
    if ($LASTEXITCODE -ne 0) { throw "Flashing failed with exit code $LASTEXITCODE" }

    Write-Host "[5/6] Flash completed and esptool verified the writes." -ForegroundColor Green
    Write-Host "[6/6] Opening the firmware console at 2,000,000 baud. Press Ctrl+] to exit." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    & py -m serial.tools.miniterm $Port 2000000
}
finally {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
