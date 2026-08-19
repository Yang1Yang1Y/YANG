[CmdletBinding()]
param(
    [string]$Version,
    [string]$InnoCompiler
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$versionInfo = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repoRoot 'version.json') | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$versionInfo.version }
if ([version]$Version -ne [version]([string]$versionInfo.version)) { throw '参数版本必须与 version.json 一致。' }

$buildRoot = Join-Path $repoRoot 'build'
$payloadRoot = Join-Path $buildRoot 'CodexUsagePet'
$distRoot = Join-Path $repoRoot 'dist'
foreach ($target in @($buildRoot,$distRoot)) {
    $full = [IO.Path]::GetFullPath($target)
    if (-not $full.StartsWith(([IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝清理仓库外目录：$full" }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
New-Item -ItemType Directory -Path $payloadRoot,$distRoot -Force | Out-Null

$files = @('CodexUsagePet.ps1','Start-CodexUsagePet.ps1','Start-CodexUsagePet.cmd','Update-CodexUsagePet.ps1','Uninstall.ps1','README.md','version.json')
foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $payloadRoot $file) -Force }
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination (Join-Path $payloadRoot 'assets') -Recurse -Force

$manifestFiles = @()
foreach ($file in @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse | Sort-Object FullName)) {
    $manifestFiles += [pscustomobject]@{
        path = $file.FullName.Substring($payloadRoot.Length).TrimStart('\').Replace('\','/')
        bytes = [int64]$file.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{ product = 'Codex 用量宠物'; version = $Version; generated_utc = [DateTime]::UtcNow.ToString('o'); files = $manifestFiles }
$manifestPath = Join-Path $payloadRoot 'release-manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $distRoot 'release-manifest.json') -Force

$zipPath = Join-Path $distRoot ("CodexUsagePet-portable-v{0}.zip" -f $Version)
Compress-Archive -Path (Join-Path $payloadRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force

if ([string]::IsNullOrWhiteSpace($InnoCompiler)) {
    $candidates = @()
    foreach ($basePath in @(${env:ProgramFiles(x86)},$env:ProgramFiles,$env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($basePath)) { continue }
        $suffix = if ($basePath -eq $env:LOCALAPPDATA) { 'Programs\Inno Setup 6\ISCC.exe' } else { 'Inno Setup 6\ISCC.exe' }
        $candidates += Join-Path $basePath $suffix
    }
    $InnoCompiler = [string]($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}
if ([string]::IsNullOrWhiteSpace($InnoCompiler) -or -not (Test-Path -LiteralPath $InnoCompiler)) { throw '找不到 Inno Setup 6 编译器 ISCC.exe。' }

$issPath = Join-Path $repoRoot 'installer\CodexUsagePet.iss'
& $InnoCompiler ("/DMyAppVersion={0}" -f $Version) ("/DSourceDir={0}" -f $payloadRoot) ("/DOutputDir={0}" -f $distRoot) $issPath
if ($LASTEXITCODE -ne 0) { throw "Inno Setup 编译失败，退出码 $LASTEXITCODE。" }

$setupPath = Join-Path $distRoot ("CodexUsagePet-Setup-v{0}.exe" -f $Version)
if (-not (Test-Path -LiteralPath $setupPath)) { throw '安装包没有生成。' }
$checksumLines = foreach ($artifact in @($setupPath,$zipPath)) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
    "{0}  {1}" -f $hash,[IO.Path]::GetFileName($artifact)
}
$checksumLines | Set-Content -LiteralPath (Join-Path $distRoot 'SHA256SUMS.txt') -Encoding ASCII
Get-ChildItem -LiteralPath $distRoot -File | Select-Object Name,Length,@{Name='SHA256';Expression={(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash}} | Format-Table -AutoSize
