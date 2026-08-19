[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Silent,
    [switch]$Install,
    [switch]$Json,
    [string]$Repository = 'Yang1Yang1Y/YANG'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionPath = Join-Path $projectRoot 'version.json'
$statePath = Join-Path $projectRoot '.update-state.json'
$logPath = Join-Path $projectRoot 'update.log'
$headers = @{ 'User-Agent' = 'CodexUsagePet-Updater'; 'Accept' = 'application/vnd.github+json' }

function Write-UpdaterLog([string]$Message) {
    try { Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) } catch {}
}

function New-UpdateResult([string]$Status, [string]$Message, [bool]$Updated = $false) {
    return [pscustomobject]@{ updated = $Updated; status = $Status; message = $Message }
}

function Save-CheckState([string]$LatestVersion) {
    try {
        @{ last_checked_utc = [DateTime]::UtcNow.ToString('o'); latest_version = $LatestVersion } |
            ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    } catch {}
}

function Test-RecentCheck {
    if ($Force -or -not (Test-Path -LiteralPath $statePath)) { return $false }
    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
        return ([DateTime]::Parse([string]$state.last_checked_utc).ToUniversalTime() -gt [DateTime]::UtcNow.AddHours(-6))
    } catch { return $false }
}

function Stop-PetProcesses {
    $petScript = [IO.Path]::GetFullPath((Join-Path $projectRoot 'CodexUsagePet.ps1'))
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and $_.Name -in @('powershell.exe','pwsh.exe') -and
        -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
        $_.CommandLine.IndexOf($petScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    foreach ($process in $processes) { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue }
    if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

function Update-UninstallRegistration([string]$NewVersion) {
    $keyName = '{D0C4EA12-A4FB-46AB-889C-BC501A20AA5F}_is1'
    $keys = @(
        ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $keyName),
        ('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $keyName),
        ('HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + $keyName)
    )
    foreach ($key in $keys) {
        try {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $registration = Get-ItemProperty -LiteralPath $key
            $registeredPath = [IO.Path]::GetFullPath([string]$registration.InstallLocation).TrimEnd('\')
            if (-not $registeredPath.Equals([IO.Path]::GetFullPath($projectRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
            Set-ItemProperty -LiteralPath $key -Name DisplayVersion -Value $NewVersion
            Set-ItemProperty -LiteralPath $key -Name DisplayName -Value 'Codex 用量宠物'
        } catch {}
    }
}

function Invoke-ReleaseUpdate {
    if (-not (Test-Path -LiteralPath $versionPath)) { return New-UpdateResult 'error' '缺少 version.json，无法识别当前版本' }
    if (Test-RecentCheck) { return New-UpdateResult 'skipped' '距离上次检查不足 6 小时，已跳过' }

    $currentInfo = Get-Content -Raw -Encoding UTF8 -LiteralPath $versionPath | ConvertFrom-Json
    $currentVersion = [version]([string]$currentInfo.version).TrimStart('v')
    $release = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers $headers -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $Repository)
    $latestText = ([string]$release.tag_name).TrimStart('v')
    $latestVersion = [version]$latestText
    Save-CheckState $latestText

    if ($latestVersion -le $currentVersion) { return New-UpdateResult 'current' ("已经是最新版本 v{0}" -f $currentVersion) }

    $zipAsset = @($release.assets | Where-Object { $_.name -eq ("CodexUsagePet-portable-v{0}.zip" -f $latestText) }) | Select-Object -First 1
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
    if ($null -eq $zipAsset -or $null -eq $checksumAsset) { return New-UpdateResult 'error' '新版本缺少便携更新包或校验文件' }

    if (-not $Install) {
        if ($Silent) { return New-UpdateResult 'available' ("发现新版本 v{0}" -f $latestText) }
        Add-Type -AssemblyName System.Windows.Forms
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "发现 Codex 用量宠物 v$latestText。`n`n当前版本：v$currentVersion`n是否立即下载并更新？",
            'Codex 用量宠物更新',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return New-UpdateResult 'declined' ("发现新版本 v{0}，本次暂不更新" -f $latestText)
        }
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsagePetUpdate-' + [Guid]::NewGuid().ToString('N'))
    $extractRoot = Join-Path $tempRoot 'payload'
    $backupRoot = Join-Path $tempRoot 'backup'
    $zipPath = Join-Path $tempRoot ([string]$zipAsset.name)
    $checksumPath = Join-Path $tempRoot 'SHA256SUMS.txt'
    New-Item -ItemType Directory -Path $extractRoot,$backupRoot -Force | Out-Null

    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Headers $headers -Uri ([string]$zipAsset.browser_download_url) -OutFile $zipPath
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Headers $headers -Uri ([string]$checksumAsset.browser_download_url) -OutFile $checksumPath
        $pattern = '^([A-Fa-f0-9]{64})\s+\*?' + [regex]::Escape([string]$zipAsset.name) + '$'
        $checksumLine = @(Get-Content -LiteralPath $checksumPath | Where-Object { $_ -match $pattern }) | Select-Object -First 1
        if ($null -eq $checksumLine) { throw '校验文件中找不到便携更新包。' }
        [void]([string]$checksumLine -match $pattern)
        $expectedHash = [string]$Matches[1]
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
        if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw '更新包 SHA256 校验失败。' }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
        $payloadRoot = $extractRoot
        if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot 'version.json'))) {
            $children = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
            if ($children.Count -eq 1) { $payloadRoot = $children[0].FullName }
        }
        $newVersionPath = Join-Path $payloadRoot 'version.json'
        if (-not (Test-Path -LiteralPath $newVersionPath)) { throw '更新包结构无效：缺少 version.json。' }
        $newInfo = Get-Content -Raw -Encoding UTF8 -LiteralPath $newVersionPath | ConvertFrom-Json
        if ([version]([string]$newInfo.version).TrimStart('v') -ne $latestVersion) { throw '更新包版本与 GitHub Release 不一致。' }

        $payloadFiles = @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse)
        foreach ($file in $payloadFiles) {
            $relative = $file.FullName.Substring($payloadRoot.Length).TrimStart('\')
            $destination = Join-Path $projectRoot $relative
            if (Test-Path -LiteralPath $destination) {
                $backup = Join-Path $backupRoot $relative
                $backupParent = Split-Path -Parent $backup
                if (-not (Test-Path -LiteralPath $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                Copy-Item -LiteralPath $destination -Destination $backup -Force
            }
        }

        Stop-PetProcesses
        try {
            foreach ($file in $payloadFiles) {
                $relative = $file.FullName.Substring($payloadRoot.Length).TrimStart('\')
                $destination = Join-Path $projectRoot $relative
                $destinationParent = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationParent)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
            }
        } catch {
            foreach ($backup in @(Get-ChildItem -LiteralPath $backupRoot -File -Recurse)) {
                $relative = $backup.FullName.Substring($backupRoot.Length).TrimStart('\')
                $destination = Join-Path $projectRoot $relative
                Copy-Item -LiteralPath $backup.FullName -Destination $destination -Force
            }
            throw
        }
        Update-UninstallRegistration $latestText
        return New-UpdateResult 'updated' ("已更新 v{0} → v{1}" -f $currentVersion,$latestVersion) $true
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

try {
    $result = Invoke-ReleaseUpdate
} catch {
    $result = New-UpdateResult 'error' ('更新失败：' + $_.Exception.Message)
}
Write-UpdaterLog $result.message
if ($Json) { $result | ConvertTo-Json -Compress } else { Write-Host $result.message }
