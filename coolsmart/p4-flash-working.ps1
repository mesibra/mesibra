param(
    [string]$Port = "COM19"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BaseUrl = "https://raw.githubusercontent.com/mesibra/mesibra/main/coolsmart/firmware/p4-c960ee6"
$ExpectedCommit = "c960ee6cf4f7ab08887577b03bd00243ef2f5c79"
$TempRoot = Join-Path $env:TEMP ("CoolSmart-P4-" + [guid]::NewGuid().ToString("N"))
$FwRoot = Join-Path $TempRoot "fw"

$Files = @(
    @{ Remote = "bootloader/bootloader.bin"; Local = "bootloader\bootloader.bin"; Sha256 = "70c836a4d616e7525c5fb65ec89aee621e38e2736978c6b051460f93392fa62a" },
    @{ Remote = "partition_table/partition-table.bin"; Local = "partition_table\partition-table.bin"; Sha256 = "3ba490af9dac62e05c22ca5a124018f5fdca958ffd1a767bb90eae7b558400df" },
    @{ Remote = "ota_data_initial.bin"; Local = "ota_data_initial.bin"; Sha256 = "7d2c7ac4888bfd75cd5f56e8d61f69595121183afc81556c876732fd3782c62f" },
    @{ Remote = "CoolSmartP4Monitor.bin"; Local = "CoolSmartP4Monitor.bin"; Sha256 = "5f2e69a409b6635be07168a207b2c4ec639be4f9179b17f085145156845985c7" },
    @{ Remote = "storage.bin"; Local = "storage.bin"; Sha256 = "c1ec6e89a70576f5f8786c56a834aa6589a2f0bb801d0bd30e76922df17ffec1" }
)

New-Item -ItemType Directory -Path $FwRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $FwRoot "bootloader") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $FwRoot "partition_table") -Force | Out-Null

try {
    Write-Host "[1/6] Checking COM port $Port..." -ForegroundColor Cyan
    $serial = Get-CimInstance Win32_SerialPort | Where-Object { $_.DeviceID -eq $Port }
    if (-not $serial) { throw "Port $Port not found." }

    Write-Host "[2/6] Downloading permanent GitHub hotfix $ExpectedCommit..." -ForegroundColor Cyan
    $commitUrl = "$BaseUrl/commit.txt"
    $actualCommit = (Invoke-RestMethod -Uri $commitUrl).Trim()
    if ($actualCommit -ne $ExpectedCommit) {
        throw "Unexpected firmware commit: $actualCommit"
    }

    foreach ($item in $Files) {
        $dest = Join-Path $FwRoot $item.Local
        $url = "$BaseUrl/$($item.Remote)"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
        $actualHash = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant()
        if ($actualHash -ne $item.Sha256) {
            throw "SHA256 mismatch for $($item.Remote). Expected $($item.Sha256), got $actualHash"
        }
    }
    Write-Host "Permanent GitHub files and SHA256 checks OK." -ForegroundColor Green

    $Boot = Join-Path $FwRoot "bootloader\bootloader.bin"
    $Part = Join-Path $FwRoot "partition_table\partition-table.bin"
    $Ota = Join-Path $FwRoot "ota_data_initial.bin"
    $App = Join-Path $FwRoot "CoolSmartP4Monitor.bin"
    $Storage = Join-Path $FwRoot "storage.bin"

    Write-Host "[3/6] Backing up current NVS regions before any write..." -ForegroundColor Cyan
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FactoryBackup = Join-Path $Desktop ("P4-nvsfactory-" + $Stamp + ".bin")
    $NvsBackup = Join-Path $Desktop ("P4-nvs-" + $Stamp + ".bin")

    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x9000 0x32000 $FactoryBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read nvsfactory; flashing stopped." }
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 read-flash 0x3b000 0xd2000 $NvsBackup
    if ($LASTEXITCODE -ne 0) { throw "Could not read NVS; flashing stopped." }
    Write-Host "NVS backups saved to Desktop." -ForegroundColor Green

    Write-Host "[4/6] Flashing exact official flash_args offsets. No full.bin and no erase-flash..." -ForegroundColor Cyan
    & py -m esptool --chip esp32p4 --port $Port --baud 460800 write-flash --flash-mode dio --flash-freq 80m --flash-size 32MB `
        0x2000 $Boot `
        0x110000 $App `
        0x8000 $Part `
        0x10d000 $Ota `
        0xa10000 $Storage
    if ($LASTEXITCODE -ne 0) { throw "Flashing failed with exit code $LASTEXITCODE" }

    Write-Host "[5/6] Hotfix flashed and verified." -ForegroundColor Green
    Write-Host "[6/6] Opening firmware console at 2,000,000 baud. Press Ctrl+] to exit." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    & py -m serial.tools.miniterm $Port 2000000
}
finally {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
