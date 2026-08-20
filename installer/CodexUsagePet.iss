#ifndef MyAppVersion
  #define MyAppVersion "3.1.2"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\CodexUsagePet"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{D0C4EA12-A4FB-46AB-889C-BC501A20AA5F}
AppName=Codex 用量宠物
AppVersion={#MyAppVersion}
UninstallDisplayName=Codex 用量宠物
AppPublisher=Yang1Yang1Y
AppPublisherURL=https://github.com/Yang1Yang1Y/YANG
AppSupportURL=https://github.com/Yang1Yang1Y/YANG/issues
AppUpdatesURL=https://github.com/Yang1Yang1Y/YANG/releases
DefaultDirName={localappdata}\Programs\Codex Usage Pet
DefaultGroupName=Codex 用量宠物
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=CodexUsagePet-Setup-v{#MyAppVersion}
SetupIconFile={#SourceDir}\assets\app.ico
UninstallDisplayIcon={app}\assets\app.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0
CloseApplications=no
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: checkedonce
Name: "autostart"; Description: "登录 Windows 后自动启动"; GroupDescription: "启动选项："; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Codex 用量宠物\Codex 用量宠物"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Start-CodexUsagePet.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"
Name: "{userprograms}\Codex 用量宠物\卸载 Codex 用量宠物"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Codex 用量宠物"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Start-CodexUsagePet.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Tasks: desktopicon
Name: "{userstartup}\Codex 用量宠物"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Start-CodexUsagePet.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\app.ico"; Tasks: autostart

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Start-CodexUsagePet.ps1"" -SkipUpdate"; WorkingDir: "{app}"; Description: "启动 Codex 用量宠物"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Uninstall.ps1"" -FromInstaller"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; RunOnceId: "StopAndCleanPet"

[UninstallDelete]
Type: files; Name: "{app}\.pet-settings.json"
Type: files; Name: "{app}\.usage-history-cache.json"
Type: files; Name: "{app}\.project-lifetime-cache.json"
Type: files; Name: "{app}\.update-state.json"
Type: files; Name: "{app}\runtime-error.log"
Type: files; Name: "{app}\update.log"
Type: dirifempty; Name: "{app}\assets\cat"
Type: dirifempty; Name: "{app}\assets"
Type: dirifempty; Name: "{app}"
