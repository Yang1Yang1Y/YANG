$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 用量宠物.lnk'
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex 用量宠物.lnk'
foreach ($shortcut in @($desktopShortcutPath, $startupShortcutPath)) {
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
}
Write-Host '快捷方式和开机启动项已移除。项目文件与用量数据未删除。'
