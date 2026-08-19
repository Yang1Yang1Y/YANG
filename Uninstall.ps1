[CmdletBinding()]
param(
    [switch]$FromInstaller
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$petScript = Join-Path $projectRoot 'CodexUsagePet.ps1'

if (-not $FromInstaller) {
    $uninstaller = Get-ChildItem -LiteralPath $projectRoot -Filter 'unins*.exe' -File | Sort-Object Name | Select-Object -First 1
    if ($null -ne $uninstaller) {
        Start-Process -FilePath $uninstaller.FullName
        return
    }
}

$resolvedPetScript = [IO.Path]::GetFullPath($petScript)
$processes = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -in @('powershell.exe','pwsh.exe') -and
    -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
    $_.CommandLine.IndexOf($resolvedPetScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
foreach ($process in $processes) { Stop-Process -Id ([int]$process.ProcessId) -Force }

$shortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 用量宠物.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 用量宠物.lnk')
)
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcut in $shortcutPaths) {
    if (-not (Test-Path -LiteralPath $shortcut)) { continue }
    $link = $shell.CreateShortcut($shortcut)
    $belongsToThisInstall =
        ([string]$link.WorkingDirectory).Equals($projectRoot, [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$link.Arguments).IndexOf($projectRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($belongsToThisInstall) { Remove-Item -LiteralPath $shortcut -Force }
}

if ($FromInstaller) {
    $manifestPath = Join-Path $projectRoot 'release-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
            $rootPrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + '\'
            foreach ($entry in @($manifest.files)) {
                $relative = ([string]$entry.path).Replace('/','\').TrimStart('\')
                $target = [IO.Path]::GetFullPath((Join-Path $projectRoot $relative))
                if ($target.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                    Remove-Item -LiteralPath $target -Force
                }
            }
        } catch {}
    }
    foreach ($dataName in @('.pet-settings.json','.usage-history-cache.json','.project-lifetime-cache.json','.update-state.json','runtime-error.log','update.log','release-manifest.json')) {
        $dataPath = Join-Path $projectRoot $dataName
        if (Test-Path -LiteralPath $dataPath -PathType Leaf) { Remove-Item -LiteralPath $dataPath -Force }
    }
} else {
    Write-Host '未检测到正式安装器；已停止程序并移除快捷方式，程序目录保持不变。'
}
