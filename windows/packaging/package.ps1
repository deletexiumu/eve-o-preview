# SPDX-License-Identifier: GPL-3.0-or-later
#
# 打发布包（docs/windows/packaging.md 第 2 节）。在 Windows 上、windows/ 目录里、发布构建之后运行：
#
#     cargo build --release --locked -p eveo-app        # 带 EVEO_BUILD_LABEL 与 EVEO_UPDATE_PUBLIC_KEY
#     pwsh packaging/package.ps1 -Version 0.9.0-beta.1 -OutDir dist
#
# 产出发布契约（架构文档 6.2 节）的前三个附件，签名在 CI 的 release 任务里做（私钥不进 Windows 运行器）：
# - EVE-O-Preview-<版本>-windows-x64.zip：根目录下的「EVE-O Preview.exe」、LICENSE.txt、README.txt；
# - eve-o-preview-<版本>-windows-source.zip：这个提交的 windows/ 与 shared/ 源码（GPL 要求），用 git archive 生成；
# - SHA256SUMS.txt：上面两个文件的 SHA-256，格式与 sha256sum 的文本模式相同（十六进制小写、两个空格、文件名），
#   行尾是 LF，签名针对的是这个文件的原始字节。
# 输出目录必须不存在或为空，免得旧文件混进发布物。

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 版本号只收语义化版本用到的字符：它会进文件名，也会被应用拿去比较。
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') {
    throw "版本号格式不对：$Version"
}
$exe = Join-Path 'target' 'release' 'eve-o-preview.exe'
if (-not (Test-Path $exe)) { throw "找不到 $exe，先做发布构建" }
if ((Test-Path $OutDir) -and (Get-ChildItem $OutDir | Measure-Object).Count -gt 0) {
    throw "输出目录 $OutDir 不是空的"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$out = (Resolve-Path $OutDir).Path

# 应用包：先在暂存目录里摆好三个文件，再整体压缩（文件都在 zip 的根目录）。
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "eveo-stage-$PID"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item $exe (Join-Path $stage 'EVE-O Preview.exe')
Copy-Item (Join-Path '..' 'LICENSE') (Join-Path $stage 'LICENSE.txt')
Copy-Item (Join-Path 'packaging' 'README.txt') (Join-Path $stage 'README.txt')
$appZip = "EVE-O-Preview-$Version-windows-x64.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $out $appZip) -CompressionLevel Optimal
Remove-Item -Recurse -Force $stage

# 源码包：这个提交的 windows/ 与 shared/，外面套一层目录。
$sourceZip = "eve-o-preview-$Version-windows-source.zip"
git -C .. archive --format=zip --prefix="eve-o-preview-$Version-windows-source/" -o (Join-Path $out $sourceZip) HEAD windows shared
if ($LASTEXITCODE -ne 0) { throw 'git archive 失败' }

# 校验和：手写成 LF 行尾的 UTF-8（无 BOM），与 sha256sum 的输出逐字节相同。
$lines = foreach ($name in @($appZip, $sourceZip)) {
    $hash = (Get-FileHash -Algorithm SHA256 (Join-Path $out $name)).Hash.ToLowerInvariant()
    "$hash  $name"
}
$text = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS.txt'), $text, (New-Object System.Text.UTF8Encoding $false))

Write-Host "已打包到 ${out}："
Get-ChildItem $out | ForEach-Object { Write-Host ("  {0}  {1} 字节" -f $_.Name, $_.Length) }
