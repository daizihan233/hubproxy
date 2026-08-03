<#
.SYNOPSIS
    构建 HubProxy 的 Azure Functions Custom Handler 部署包。

.DESCRIPTION
    1. 编译前端 (web/) 到 src/dist（可用 -SkipFrontend 复用已有产物）
    2. 交叉编译 Go 二进制 (linux/amd64 或 linux/arm64)
    3. 组装 Azure Functions 目录结构 (host.json + proxy/)
    4. 打包为 zip，可直接部署到 Azure Functions (Linux)

.EXAMPLE
    ./build-azure.ps1                # 默认构建 linux/amd64
    ./build-azure.ps1 -Arch arm64   # 构建 linux/arm64
    ./build-azure.ps1 -SkipFrontend # 跳过前端编译（复用已有 src/dist）
#>
param(
    [ValidateSet("amd64", "arm64")]
    [string]$Arch = "amd64",
    [switch]$SkipFrontend,
    [string]$Version = "dev"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $root "build/azure-functions"
$distDir = Join-Path $root "src/dist"

Write-Host "==> 构建 Azure Functions 部署包 (GOARCH=$Arch, 版本=$Version)" -ForegroundColor Cyan

# 1. 前端编译
if (-not $SkipFrontend) {
    Write-Host "==> 编译前端..."
    Push-Location (Join-Path $root "web")
    try {
        if (-not (Test-Path "node_modules")) { npm ci }
        npm run build
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $distDir)) {
    Write-Error "前端产物缺失: $distDir。请先运行前端编译或使用 -SkipFrontend。"
}

# 2. 交叉编译 Go 二进制
Write-Host "==> 编译 Go 二进制 (linux/$Arch)..."
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$env:CGO_ENABLED = "0"
$env:GOOS = "linux"
$env:GOARCH = $Arch
Push-Location (Join-Path $root "src")
try {
    go build -ldflags="-s -w -X main.Version=$Version" -trimpath -o "$outDir/hubproxy" .
} finally {
    Pop-Location
}

# 3. 组装 Azure Functions 目录
Write-Host "==> 组装 Azure Functions 目录..."
Copy-Item -Path (Join-Path $root "azure/host.json") -Destination $outDir -Force
if (Test-Path (Join-Path $root "azure/proxy")) {
    Copy-Item -Path (Join-Path $root "azure/proxy") -Destination $outDir -Recurse -Force
}
Copy-Item -Path (Join-Path $root "src/config.toml") -Destination $outDir -Force

# 4. 打包
$zip = Join-Path $root "build/hubproxy-azure-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zip

Write-Host ""
Write-Host "Azure Functions 部署包已生成: $zip" -ForegroundColor Green
Write-Host "内容:"
Get-ChildItem -Path $outDir -Recurse | Select-Object FullName