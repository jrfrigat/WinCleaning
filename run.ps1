# WinCleaning launcher for running straight from GitHub:
#   irm https://raw.githubusercontent.com/jrfrigat/WinCleaning/main/run.ps1 | iex
# Downloads Clean-All.ps1 to a temp file and runs it from there: Windows PowerShell 5.1
# needs the file (with its UTF-8 BOM) to read the Cyrillic text correctly.
# Keep this file ASCII-only and without a BOM, otherwise "irm | iex" breaks.
param(
    [string]$Steps,
    [switch]$Yes,
    [switch]$NoPause
)

$url = "https://raw.githubusercontent.com/jrfrigat/WinCleaning/main/Clean-All.ps1"
$file = Join-Path $env:TEMP "WinCleaning\Clean-All.ps1"
New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Host "WinCleaning: download failed: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $file)
if ($Steps)   { $argList += @("-Steps", "$Steps") }
if ($Yes)     { $argList += "-Yes" }
if ($NoPause) { $argList += "-NoPause" }
& powershell.exe @argList
