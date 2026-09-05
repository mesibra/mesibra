param(
    [string]$Port = "COM19"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BaseUrl = "https://raw.githubusercontent.com/mesibra/mesibra/main/coolsmart/firmware/p4-f863a67"
$ExpectedCommit = "f863a67b9510f2c9a6181e092aaa32dd81fc9d0d"
$TempRoot = Join-Path $env:TEMP ("CoolSmart-P4-PhoneSetup-" + [guid]::NewGuid().ToString("N"))
$FwRoot = Join-Path $TempRoot "fw"

$Files = @(
    @{ Remote = "bootloader/bootloader.bin"; Local = "bootloader\bootloader.bin"; Sha256 = "1a3d4f88efb15649d5766bd05520c26e2a84d38f3cf6f19d6a1ffcbc06d4efb9" },
    @{ Remote = "partition_table/partition-table.bin"; Local = "partition_table\partition-table.bin"; Sha256 = "3ba490af9dac62e05c22ca5a124018f5fdca958ffd1a767bb90eae7b558400df" },
    @{ Remote = "ota_data_initial.bin"; Local = "ota_data_initial.bin"; Sha256 = "7d2c7ac4888bfd75cd5f56e8d61f69595121183afc81556c876732fd3782c62f" },
    @{ Remote = "CoolSmartP4Monitor.bin"; Local = "CoolSmartP4Monitor.bin"; Sha256 = "7bd2d9709d463f7fe173d317399205ce790a308803b833f5e4bbda7399913880" },
    @{ Remote = "storage.bin"; Local = "storage.bin"; Sha256 = "c1ec6e89a70576f5f8786c56a834aa6589a2f0bb801d0bd30e76922df17ffec1" }
)

function Read-FlashRegionSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Offset,
        [Parameter(Mandatory = $true)][string]$Size,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $Bauds = @(230400, 115200)
    foreach ($baud in $Bauds) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
            }

            Write-Host ("Reading {0} at {1} baud (attempt {2}/2)..." -f $Label, $baud, $attempt) -ForegroundColor DarkCyan
            & py -m esptool --chip esp32p4 --port $Port --baud $baud read-flash $Offset $Size $Destination
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0 -and (Test-Path $Destination)) {
                $actualBytes = (Get-Item $Destination).Length
                if ($actualBytes -eq $ExpectedBytes) {
                    Write-Host ("{0} backup OK ({1} bytes)." -f $Label, $actualBytes) -ForegroundColor Green
                    return
                }
                Write-Warning ("{0} backup size mismatch: expected {1}, got {2}. Retrying at safer speed." -f $Label, $ExpectedBytes, $actualBytes)
            }
            else {
                Write-Warning ("{0} read failed at {1} baud. Retrying safely." -f $Label, $baud)
            }

            Start-Sleep -Seconds 2
        }
    }

    if (Test-Path $Destination) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    }
    throw "$Label backup could not be read and verified after safe retries; flashing stopped before any write."
}

New-Item -ItemType Directory -Path $FwRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $FwRoot "bootloader") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $FwRoot "partition_table") -Force | Out-Null

try {
    Write-Host "[1/7] Checking COM port $Port..." -ForegroundColor Cyan
    $serial = Get-CimInstance Win32_SerialPort | Where-Object { $_.DeviceID -eq $Port }
    if (-not $serial) { throw "Port $Port not found." }

    Write-Host "[2/7] Downloading permanent GitHub P4 Ethernet/Wi-Fi build $ExpectedCommit..." -ForegroundColor Cyan
    $actualCommit = (Invoke-RestMethod -Uri "$BaseUrl/commit.txt").Trim()
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
    Write-Host "Permanent GitHub files, commit and SHA256 checks OK." -ForegroundColor Green

    Write-Host "[3/7] Checking esptool..." -ForegroundColor Cyan
    & py -m esptool version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Python/esptool not available." }

    $Boot = Join-Path $FwRoot "bootloader\bootloader.bin"
    $Part = Join-Path $FwRoot "partition_table\partition-table.bin"
    $Ota = Join-Path $FwRoot "ota_data_initial.bin"
    $App = Join-Path $FwRoot "CoolSmartP4Monitor.bin"
    $Storage = Join-Path $FwRoot "storage.bin"

    Write-Host "[4/7] Backing up current NVS regions before any write..." -ForegroundColor Cyan
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $FactoryBackup = Join-Path $Desktop ("P4-nvsfactory-" + $Stamp + ".bin")
    $NvsBackup = Join-Path $Desktop ("P4-nvs-" + $Stamp + ".bin")

    Read-FlashRegionSafe -Offset "0x9000" -Size "0x32000" -ExpectedBytes 204800 -Destination $FactoryBackup -Label "nvsfactory"
    Read-FlashRegionSafe -Offset "0x3b000" -Size "0xd2000" -ExpectedBytes 860160 -Destination $NvsBackup -Label "NVS"
    Write-Host "Both NVS backups are complete and size-verified on Desktop." -ForegroundColor Green

    Write-Host "[5/7] Flashing safe explicit offsets at 230400 baud. NO erase-flash. NO full.bin." -ForegroundColor Cyan
    & py -m esptool --chip esp32p4 --port $Port --baud 230400 write-flash --flash-mode dio --flash-freq 80m --flash-size 32MB `
        0x2000 $Boot `
        0x110000 $App `
        0x8000 $Part `
        0x10d000 $Ota `
        0xa10000 $Storage
    if ($LASTEXITCODE -ne 0) { throw "Flashing failed with exit code $LASTEXITCODE" }

    Write-Host "[6/7] Stable Ethernet/Wi-Fi phone-setup firmware f863a67 flashed successfully." -ForegroundColor Green
    Write-Host "[7/7] Opening firmware console at 2,000,000 baud. Press Ctrl+] to exit." -ForegroundColor Cyan
    Start-Sleep -Seconds 1
    & py -m serial.tools.miniterm $Port 2000000
}
finally {
    if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
