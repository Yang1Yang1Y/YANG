[CmdletBinding()]
param(
    [switch]$EnableAutoStart
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$petScript = Join-Path $projectRoot 'CodexUsagePet.ps1'
$launcherScript = Join-Path $projectRoot 'Start-CodexUsagePet.ps1'
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $petScript)) {
    throw "找不到程序：$petScript"
}
$startupScript = if (Test-Path -LiteralPath $launcherScript) { $launcherScript } else { $petScript }
$petArguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`""

$shell = New-Object -ComObject WScript.Shell
$desktopPath = [Environment]::GetFolderPath('Desktop')
$desktopShortcutPath = Join-Path $desktopPath 'Codex 用量宠物.lnk'
$desktopShortcut = $shell.CreateShortcut($desktopShortcutPath)
$desktopShortcut.TargetPath = $powerShellExe
$desktopShortcut.Arguments = $petArguments
$desktopShortcut.WorkingDirectory = $projectRoot
$desktopShortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$desktopShortcut.Description = '显示 Codex Token 与额度用量'
$desktopShortcut.Save()

if ($EnableAutoStart) {
    $startupPath = [Environment]::GetFolderPath('Startup')
    $startupShortcutPath = Join-Path $startupPath 'Codex 用量宠物.lnk'
    $startupShortcut = $shell.CreateShortcut($startupShortcutPath)
    $startupShortcut.TargetPath = $powerShellExe
    $startupShortcut.Arguments = $petArguments
    $startupShortcut.WorkingDirectory = $projectRoot
    $startupShortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
    $startupShortcut.Description = '登录 Windows 后启动 Codex 用量宠物'
    $startupShortcut.Save()
}

Start-Process -FilePath $powerShellExe -ArgumentList $petArguments -WorkingDirectory $projectRoot -WindowStyle Hidden
Write-Host "安装完成：$desktopShortcutPath"
if ($EnableAutoStart) { Write-Host '已启用开机启动。' }
