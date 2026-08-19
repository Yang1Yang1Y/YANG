[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [switch]$EnableAutoStart,
    [switch]$Silent,
    [string]$Repository = 'Yang1Yang1Y/YANG'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$setup = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'dist') -Filter 'CodexUsagePet-Setup-v*.exe' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$downloadRoot = $null

try {
    if ($null -eq $setup) {
        $headers = @{ 'User-Agent' = 'CodexUsagePet-Installer' }
        $release = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers $headers -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repository)
        $asset = @($release.assets | Where-Object { $_.name -match '^CodexUsagePet-Setup-v[0-9].*\.exe$' }) | Select-Object -First 1
        $checksumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
        if ($null -eq $asset -or $null -eq $checksumAsset) { throw '最新版本缺少 Windows 安装包或校验文件。' }
        $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsagePetInstaller-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
        $setupPath = Join-Path $downloadRoot ([string]$asset.name)
        $checksumPath = Join-Path $downloadRoot 'SHA256SUMS.txt'
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Headers $headers -Uri ([string]$asset.browser_download_url) -OutFile $setupPath
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Headers $headers -Uri ([string]$checksumAsset.browser_download_url) -OutFile $checksumPath
        $pattern = '^([A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape([string]$asset.name) + '$'
        $line = @(Get-Content -LiteralPath $checksumPath | Where-Object { $_ -match $pattern }) | Select-Object -First 1
        if ($null -eq $line) { throw '校验文件中找不到安装包。' }
        [void]([string]$line -match $pattern)
        if (-not (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.Equals([string]$Matches[1], [StringComparison]::OrdinalIgnoreCase)) {
            throw '安装包 SHA256 校验失败。'
        }
    } else {
        $setupPath = $setup.FullName
    }

    $arguments = @('/CURRENTUSER')
    if ($Silent) { $arguments += @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') }
    if (-not [string]::IsNullOrWhiteSpace($InstallDirectory)) { $arguments += ('/DIR="{0}"' -f $InstallDirectory) }
    if ($EnableAutoStart) { $arguments += '/TASKS="desktopicon,autostart"' }
    $process = Start-Process -FilePath $setupPath -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "安装程序返回错误代码 $($process.ExitCode)。" }
} finally {
    if ($null -ne $downloadRoot -and (Test-Path -LiteralPath $downloadRoot)) {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
