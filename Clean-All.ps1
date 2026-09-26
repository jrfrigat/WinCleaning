<#
.SYNOPSIS
    WinCleaning: очистка диска Windows — Docker (со сжатием VHDX), кэши браузеров и драйверов,
    временные файлы, старые обновления Windows.
.DESCRIPTION
    1. Docker: удаляет всё, что не привязано ни к одному контейнеру (в том числе остановленному):
       тома, образы, кэш сборки, сети. Остановленные контейнеры и их данные сохраняются.
    2. Останавливает Docker Desktop и WSL, сжимает VHDX-диски Docker, запускает Docker Desktop обратно.
    3. Кэши браузеров (Chrome, Chrome Canary, Edge, Яндекс, Brave, Opera, Firefox) — только кэш;
       пароли, cookies, история, закладки и расширения не затрагиваются.
    4. Кэши шейдеров и старые установщики драйверов NVIDIA/AMD/Intel, кэш DirectX.
    5. Temp, кэши NuGet/npm, WorkspaceStorage VS Code, дампы падений, корзина.
    6. Старые обновления Windows (DISM StartComponentCleanup, SoftwareDistribution\Download, Delivery Optimization).
    Сам перезапускается с правами администратора. Можно запускать прямо с GitHub:
        irm https://raw.githubusercontent.com/jrfrigat/WinCleaning/main/run.ps1 | iex
.PARAMETER Steps
    Номера шагов через запятую, например "1,2,5". Без него скрипт покажет меню выбора.
.PARAMETER Yes
    Не задавать вопросов: выполнить все шаги (или шаги из -Steps), удалить тома и закрыть браузеры без подтверждения.
.PARAMETER NoPause
    Не ждать нажатия клавиши в конце.
.PARAMETER UserLocalAppData
    Служебный: папка LocalAppData пользователя, запустившего скрипт (передаётся при перезапуске от администратора).
.PARAMETER UserAppData
    Служебный: папка AppData\Roaming пользователя, запустившего скрипт.
.PARAMETER UserTemp
    Служебный: папка Temp пользователя, запустившего скрипт.
.EXAMPLE
    .\Clean-All.ps1
.EXAMPLE
    .\Clean-All.ps1 -Steps 3,4,5
.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jrfrigat/WinCleaning/main/run.ps1))) -Steps 3,4,5
#>

param(
    [string]$Steps,
    [switch]$Yes,
    [switch]$NoPause,
    [string]$UserLocalAppData = $env:LOCALAPPDATA,
    [string]$UserAppData = $env:APPDATA,
    [string]$UserTemp = $env:TEMP
)

# --- Права администратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Запрашиваем права администратора..." -ForegroundColor Yellow
    # Передаём папки текущего пользователя: администратор может оказаться другой учётной записью
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
                 "-UserLocalAppData", "`"$UserLocalAppData`"", "-UserAppData", "`"$UserAppData`"", "-UserTemp", "`"$UserTemp`"")
    if ($Steps)   { $argList += @("-Steps", "`"$Steps`"") }
    if ($Yes)     { $argList += "-Yes" }
    if ($NoPause) { $argList += "-NoPause" }
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "Права администратора не получены, очистка отменена." -ForegroundColor Red
    }
    return
}

$L = $UserLocalAppData
$R = $UserAppData
$SysDrive = $env:SystemDrive
$WinDir = $env:SystemRoot

# Docker Desktop: стандартная папка или рядом с docker.exe (...\Docker\Docker\resources\bin\docker.exe)
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
if (-not (Test-Path $DockerExe)) {
    $dockerCli = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerCli) {
        $candidate = Join-Path (Split-Path (Split-Path (Split-Path $dockerCli.Source))) "Docker Desktop.exe"
        if (Test-Path $candidate) { $DockerExe = $candidate }
    }
}

# Диски Docker: WSL 2 (docker_data.vhdx, ext4.vhdx) и старый режим Hyper-V (DockerDesktop.vhdx)
$DockerWsl = Join-Path $L "Docker\wsl"
$VhdxFiles = @(
    (Join-Path $DockerWsl "disk\docker_data.vhdx"),
    (Join-Path $DockerWsl "main\ext4.vhdx"),
    (Join-Path $env:ProgramData "DockerDesktop\vm-data\DockerDesktop.vhdx")
) | Where-Object { Test-Path $_ }

# Chromium-браузеры: папка User Data и имена процессов
$ChromiumBrowsers = @(
    @{ Name = "Chrome";        Data = "$L\Google\Chrome\User Data";               Process = "chrome"; Exe = "\Google\Chrome\" },
    @{ Name = "Chrome Canary"; Data = "$L\Google\Chrome SxS\User Data";           Process = "chrome"; Exe = "\Google\Chrome SxS\" },
    @{ Name = "Edge";          Data = "$L\Microsoft\Edge\User Data";              Process = "msedge" },
    @{ Name = "Яндекс";        Data = "$L\Yandex\YandexBrowser\User Data";        Process = "browser" },
    @{ Name = "Brave";         Data = "$L\BraveSoftware\Brave-Browser\User Data"; Process = "brave" },
    @{ Name = "Opera";         Data = "$R\Opera Software\Opera Stable";           Process = "opera" },
    @{ Name = "Opera GX";      Data = "$R\Opera Software\Opera GX Stable";        Process = "opera" }
) | Where-Object { Test-Path $_.Data }

# Папки кэша внутри профиля и в корне User Data (пароли, cookies, история лежат в других файлах)
$ProfileCacheDirs = @("Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                      "Service Worker\CacheStorage", "Service Worker\ScriptCache")
$RootCacheDirs    = @("ShaderCache", "GrShaderCache", "GraphiteDawnCache", "component_crx_cache")

function Get-FreeBytes { (Get-PSDrive $SysDrive.TrimEnd(':')).Free }
function Get-FreeGB { [math]::Round((Get-FreeBytes) / 1GB, 1) }

# Замер свободного места по шагам: каждый Write-Step закрывает предыдущий шаг
$StepResults = New-Object System.Collections.Generic.List[object]
$CurrentStep = $null

function Complete-Step {
    if (-not $script:CurrentStep) { return }
    $after = Get-FreeBytes
    $script:StepResults.Add([pscustomobject]@{
        "Шаг"            = $script:CurrentStep.Name
        "Свободно до"    = "{0:N1} ГБ" -f ($script:CurrentStep.Before / 1GB)
        "Свободно после" = "{0:N1} ГБ" -f ($after / 1GB)
        "Освобождено"    = "{0:N2} ГБ" -f (($after - $script:CurrentStep.Before) / 1GB)
    })
    $script:CurrentStep = $null
}

function Write-Step($text) {
    Complete-Step
    $script:CurrentStep = @{ Name = ($text -replace '^\d+/\d+ ', '' -replace ' \(.*\)$', ''); Before = Get-FreeBytes }
    Write-Host "`n=== $text ===" -ForegroundColor Cyan
}

function Get-SizeGB($path) { [math]::Round((Get-Item $path).Length / 1GB, 1) }

function Confirm-Action($question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$question (y/n)"
    return ($answer -match '^(y|д)')
}

# Удаляет содержимое папки; занятые файлы пропускаются
function Clear-Folder($path) {
    if (Test-Path -LiteralPath $path) {
        Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-DockerReady {
    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Start-DockerAndWait([int]$TimeoutSec = 180) {
    if (Test-DockerReady) { return $true }
    if (-not (Test-Path $DockerExe)) { return $false }
    Write-Host "Запускаем Docker Desktop и ждём готовности..." -ForegroundColor Gray
    Start-Process $DockerExe
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-DockerReady) { return $true }
    }
    return $false
}

function Stop-DockerAndWsl {
    Write-Host "Останавливаем Docker Desktop..." -ForegroundColor Gray
    Get-Process -Name "Docker Desktop", "com.docker.backend", "com.docker.build", "dockerd" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Останавливаем WSL..." -ForegroundColor Gray
    wsl --shutdown
    Start-Sleep -Seconds 5
}

function Compact-Vhdx($path) {
    $before = Get-SizeGB $path
    Write-Host "Сжимаем $path ($before ГБ)..." -ForegroundColor Magenta

    if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) {
        try {
            Mount-VHD -Path $path -ReadOnly -NoDriveLetter -ErrorAction Stop
            try     { Optimize-VHD -Path $path -Mode Full -ErrorAction Stop }
            finally { Dismount-VHD -Path $path -ErrorAction SilentlyContinue }
        } catch {
            Write-Host "Optimize-VHD не сработал ($($_.Exception.Message)), пробуем diskpart." -ForegroundColor Yellow
            Compact-VhdxDiskpart $path
        }
    } else {
        Compact-VhdxDiskpart $path
    }

    $after = Get-SizeGB $path
    Write-Host ("Готово: {0} ГБ -> {1} ГБ" -f $before, $after) -ForegroundColor Green
}

function Compact-VhdxDiskpart($path) {
    $script = @"
select vdisk file="$path"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $script | Out-File -FilePath $tempFile -Encoding ASCII
        diskpart /s $tempFile | Out-Host
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-BrowserProcesses($browser) {
    Get-Process -Name $browser.Process -ErrorAction SilentlyContinue |
        Where-Object { -not $browser.Exe -or ($_.Path -and $_.Path -like "*$($browser.Exe)*") }
}

function Close-Browser($browser) {
    $procs = @(Get-BrowserProcesses $browser)
    if (-not $procs) { return }
    # Сначала просим закрыться штатно, потом добиваем
    $procs | ForEach-Object { $null = $_.CloseMainWindow() }
    Start-Sleep -Seconds 5
    Get-BrowserProcesses $browser | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

function Wait-KeyPress {
    if (-not $NoPause) {
        Write-Host "`nНажмите любую клавишу для выхода..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

$StepNames = @{
    1 = "Docker: неиспользуемые тома, образы, кэш сборки"
    2 = "Сжатие дисков Docker (VHDX), перезапуск Docker Desktop"
    3 = "Кэши браузеров (пароли и cookies не трогаются)"
    4 = "Кэши драйверов и видеокарты"
    5 = "Temp, кэши NuGet/npm/VS Code, дампы, корзина"
    6 = "Старые обновления Windows"
}
$StepNumbers = @($StepNames.Keys | Sort-Object)

# Возвращает выбранные номера шагов или пустой список, если пользователь вышел
function Select-Steps {
    $selected = @{}
    foreach ($n in $StepNumbers) { $selected[$n] = $true }
    while ($true) {
        Write-Host "`nВыберите шаги очистки:" -ForegroundColor Cyan
        foreach ($n in $StepNumbers) {
            $mark = if ($selected[$n]) { "[x]" } else { "[ ]" }
            Write-Host ("  {0} {1}. {2}" -f $mark, $n, $StepNames[$n])
        }
        Write-Host "Номера через запятую - переключить, a - все, n - ни одного, Enter - начать, 0 - выход" -ForegroundColor Gray
        $answer = "$(Read-Host '>')".Trim().ToLower()
        if ($answer -eq "") {
            $chosen = @($StepNumbers | Where-Object { $selected[$_] })
            if ($chosen) { return $chosen }
            Write-Host "Не выбрано ни одного шага." -ForegroundColor Yellow
        } elseif ($answer -eq "0") {
            return @()
        } elseif ($answer -in @("a", "ф")) {
            foreach ($n in $StepNumbers) { $selected[$n] = $true }
        } elseif ($answer -in @("n", "т")) {
            foreach ($n in $StepNumbers) { $selected[$n] = $false }
        } else {
            foreach ($part in $answer -split '[,\s]+') {
                $n = 0
                if ([int]::TryParse($part, [ref]$n) -and $selected.ContainsKey($n)) { $selected[$n] = -not $selected[$n] }
            }
        }
    }
}

Write-Host "WinCleaning - очистка диска Windows" -ForegroundColor White

if ($Steps) {
    $SelectedSteps = @($Steps -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Where-Object { $StepNames.ContainsKey($_) })
} elseif ($Yes) {
    $SelectedSteps = $StepNumbers
} else {
    $SelectedSteps = @(Select-Steps)
}
if (-not $SelectedSteps) {
    Write-Host "Шаги не выбраны, выходим." -ForegroundColor Gray
    return
}
function Test-Step([int]$n) { return $SelectedSteps -contains $n }

Write-Host "`nБудут выполнены шаги: $($SelectedSteps -join ', ')" -ForegroundColor White
$freeStart = Get-FreeGB
Write-Host "Свободно на ${SysDrive} до очистки: $freeStart ГБ" -ForegroundColor White

# --- Вопросы заранее, чтобы дальше всё шло без участия ---
$dockerAvailable = [bool](Get-Command docker -ErrorAction SilentlyContinue)
$dockerReady = (Test-Step 1) -and $dockerAvailable -and (Start-DockerAndWait)
$pruneVolumes = $false
if ($dockerReady) {
    $unusedVolumes = @(docker volume ls -q --filter dangling=true)
    if ($unusedVolumes) {
        Write-Host "`nНеиспользуемые тома Docker (будут удалены вместе с данными):" -ForegroundColor Yellow
        $unusedVolumes | ForEach-Object { Write-Host "  $_" }
        $pruneVolumes = Confirm-Action "Удалить эти тома?"
    }
} elseif ((Test-Step 1) -and $dockerAvailable) {
    Write-Host "Docker не запустился, очистку внутри Docker пропустим." -ForegroundColor Yellow
}

$browsersToClean = @()
foreach ($browser in $(if (Test-Step 3) { $ChromiumBrowsers })) {
    if (Get-BrowserProcesses $browser) {
        if (Confirm-Action "$($browser.Name) запущен. Закрыть его, чтобы очистить кэш?") {
            $browser.Close = $true
            $browsersToClean += $browser
        } else {
            Write-Host "Кэш $($browser.Name) пропускаем." -ForegroundColor Gray
        }
    } else {
        $browsersToClean += $browser
    }
}

# --- 1. Docker ---
if (Test-Step 1) {
    Write-Step "1/6 Docker"
    if ($dockerReady) {
        docker system df
        if ($pruneVolumes) {
            # До Docker 23 volume prune и так удалял все неиспользуемые тома, а ключа -a не было
            $serverMajor = 0
            [int]::TryParse(("$(docker version --format '{{.Server.Version}}')" -split '\.')[0], [ref]$serverMajor) | Out-Null
            if ($serverMajor -ge 23) { docker volume prune -a -f } else { docker volume prune -f }
        }
        docker image prune -a -f
        docker builder prune -a -f
        docker network prune -f
        docker system df
    } else {
        Write-Host "Пропущено." -ForegroundColor Gray
    }
}

# --- 2. Сжатие VHDX ---
if (Test-Step 2) {
    Write-Step "2/6 Сжатие дисков Docker"
    if (-not $VhdxFiles) {
        Write-Host "VHDX-файлы Docker не найдены." -ForegroundColor Yellow
    } else {
        # Помечаем освобождённые блоки, чтобы сжатие их вернуло
        wsl -d docker-desktop -u root fstrim -a 2>&1 | Out-Null
        Stop-DockerAndWsl
        foreach ($vhdx in $VhdxFiles) { Compact-Vhdx $vhdx }
        if (Test-Path $DockerExe) {
            Start-Process $DockerExe
            Write-Host "Docker Desktop запускается." -ForegroundColor Gray
        }
    }
}

# --- 3. Кэши браузеров ---
if (Test-Step 3) {
    Write-Step "3/6 Кэши браузеров"
    foreach ($browser in $browsersToClean) {
        if ($browser.Close) { Close-Browser $browser }
        Write-Host "Очистка кэша $($browser.Name)" -ForegroundColor Gray
        foreach ($dir in $RootCacheDirs) { Clear-Folder (Join-Path $browser.Data $dir) }
        $profiles = @(Get-Item -LiteralPath $browser.Data) + @(Get-ChildItem -LiteralPath $browser.Data -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($profile in $profiles) {
            foreach ($dir in $ProfileCacheDirs) { Clear-Folder (Join-Path $profile.FullName $dir) }
        }
    }
    $ffRoot = "$L\Mozilla\Firefox\Profiles"
    if (Test-Path $ffRoot) {
        if (Get-Process firefox -ErrorAction SilentlyContinue) {
            Write-Host "Firefox запущен, его кэш пропускаем." -ForegroundColor Gray
        } else {
            Write-Host "Очистка кэша Firefox" -ForegroundColor Gray
            Get-ChildItem $ffRoot -Directory | ForEach-Object {
                Clear-Folder (Join-Path $_.FullName "cache2")
                Clear-Folder (Join-Path $_.FullName "startupCache")
            }
        }
    }
}

# --- 4. Кэши драйверов ---
if (Test-Step 4) {
    Write-Step "4/6 Кэши драйверов и видеокарты"
    $driverCaches = @(
        "$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\NVIDIA Corporation\NV_Cache",
        "$env:ProgramData\NVIDIA Corporation\Downloader",
        "$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts",
        "$L\AMD\DxCache", "$L\AMD\DxcCache", "$L\AMD\GLCache", "$L\AMD\VkCache", "$SysDrive\AMD",
        "$L\Intel\ShaderCache", "$L\D3DSCache"
    )
    foreach ($dir in $driverCaches) {
        if (Test-Path -LiteralPath $dir) {
            Write-Host "Очистка $dir" -ForegroundColor Gray
            Clear-Folder $dir
        }
    }
}

# --- 5. Temp и кэши разработки ---
if (Test-Step 5) {
    Write-Step "5/6 Временные файлы и кэши разработки"
    $tempDirs = @(
        $UserTemp, "$WinDir\Temp", "$L\CrashDumps", "$WinDir\Minidump",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$R\Code\User\workspaceStorage"
    )
    foreach ($dir in $tempDirs) {
        if (Test-Path -LiteralPath $dir) {
            Write-Host "Очистка $dir" -ForegroundColor Gray
            Clear-Folder $dir
        }
    }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        Write-Host "Очистка кэша NuGet" -ForegroundColor Gray
        dotnet nuget locals all --clear | Out-Null
    }
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Host "Очистка кэша npm" -ForegroundColor Gray
        npm cache clean --force 2>&1 | Out-Null
    }
    Write-Host "Очистка корзины" -ForegroundColor Gray
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

# --- 6. Старые обновления Windows ---
if (Test-Step 6) {
    Write-Step "6/6 Старые обновления Windows (может занять несколько минут)"
    Write-Host "Очистка загруженных обновлений" -ForegroundColor Gray
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Clear-Folder "$WinDir\SoftwareDistribution\Download"
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Write-Host "Очистка кэша оптимизации доставки" -ForegroundColor Gray
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Удаление заменённых компонентов Windows (DISM)" -ForegroundColor Gray
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet /NoRestart
}

# --- Итог ---
Complete-Step
$freeEnd = Get-FreeGB
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "Итоги по шагам:" -ForegroundColor Green
$StepResults | Format-Table -AutoSize | Out-Host
if ((Test-Step 1) -or (Test-Step 2)) {
    Write-Host "Место, освобождённое внутри Docker, появляется на диске только после сжатия (шаг 2)." -ForegroundColor Gray
}
Write-Host ("Свободно на {0} было {1} ГБ, стало {2} ГБ (+{3} ГБ)" -f $SysDrive, $freeStart, $freeEnd, [math]::Round($freeEnd - $freeStart, 1)) -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green

Wait-KeyPress
