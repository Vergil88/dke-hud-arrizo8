# DKE HUD App — 构建 + 自动归档
# 用法: .\build_and_archive.ps1 [-deploy 3f82acea]
param([string]$deploy = '')

$ErrorActionPreference = 'Stop'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$archiveDir = Join-Path (Split-Path -Parent $srcDir) 'apk_archive'

Write-Host '=== Building DKE HUD App ===' -ForegroundColor Cyan

Push-Location $srcDir
try {
    # 清理上一次构建时间戳 (强制重新编译 Dart)
    $buildStamp = Join-Path $srcDir 'build\app\outputs\flutter-apk\app-debug.apk'
    if (Test-Path $buildStamp) { Remove-Item $buildStamp -Force }

    $result = flutter build apk --debug 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BUILD FAILED" -ForegroundColor Red
        Write-Host ($result -join "`n")
        exit 1
    }

    Write-Host 'Build OK' -ForegroundColor Green

    # 归档 (自动递增版本号)
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory $archiveDir -Force | Out-Null }
    $apk = Join-Path $srcDir 'build\app\outputs\flutter-apk\app-debug.apk'
    $hash = (Get-FileHash -Algorithm SHA1 $apk).Hash
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $short = $hash.Substring(0, 8)

    # 读取版本号计数器
    $verFile = Join-Path $archiveDir '.version'
    $ver = 1
    if (Test-Path $verFile) {
        $ver = [int](Get-Content $verFile) + 1
    }
    $ver.ToString() | Set-Content $verFile

    $archName = "DKE_Arrizo8_v${ver}_${ts}_${short}.apk"
    Copy-Item $apk (Join-Path $archiveDir $archName)
    Write-Host "Archived: $archName (v$ver)" -ForegroundColor Green

    # 部署
    if ($deploy) {
        $adb = 'C:\Program Files (x86)\Android\android-sdk\platform-tools\adb.exe'
        Write-Host "Deploying to $deploy..." -ForegroundColor Yellow
        & $adb -s $deploy install -r $apk
        Write-Host 'Deploy OK' -ForegroundColor Green
    }

} finally {
    Pop-Location
}
