; Evenly for Windows: installer (Inno Setup 6). Build: iscc /DAppVer=0.2.4 /DSrcDir=<folder with the 4 package files> evenly.iss
#ifndef AppVer
  #define AppVer "0.0.0"
#endif
#ifndef SrcDir
  #define SrcDir "..\..\dist-win\Evenly-" + AppVer + "-windows"
#endif

[Setup]
AppId={{7C1E5D5A-2B8F-4E0A-9C61-3F0E4B1A7D20}
AppName=Evenly
AppVersion={#AppVer}
AppPublisher=Evenly
AppPublisherURL=https://evenlymac.github.io/
DefaultDirName={autopf}\Evenly
DefaultGroupName=Evenly
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist-win
OutputBaseFilename=Evenly-{#AppVer}-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Evenly
UninstallDisplayIcon={app}\evenly-tray.exe
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
english.EffectTask=Turn on the system-wide effect now (the audio service restarts, sound pauses for a second)
russian.EffectTask=Включить системный эффект сейчас (служба звука перезапустится, звук прервётся на секунду)
english.EffectStatus=Turning on the system-wide effect...
russian.EffectStatus=Включаю системный эффект...
english.EffectOffStatus=Removing the system-wide effect...
russian.EffectOffStatus=Убираю системный эффект...
english.EffectFailed=The program is installed, but the system-wide effect could not be turned on (exit code %1). You can turn it on later from the Evenly tray menu: "Turn On System-Wide Effect...".
russian.EffectFailed=Программа установлена, но системный эффект включить не удалось (код %1). Его можно включить позже из меню Evenly в трее: «Включить системный эффект…».
english.LaunchTray=Start Evenly
russian.LaunchTray=Запустить Evenly

[Tasks]
Name: "effect"; Description: "{cm:EffectTask}"

[Files]
Source: "{#SrcDir}\evenly-tray.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\evenly_apo.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\evenly-apo.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SrcDir}\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Evenly"; Filename: "{app}\evenly-tray.exe"

[Run]
Filename: "{app}\evenly-tray.exe"; Description: "{cm:LaunchTray}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "taskkill.exe"; Parameters: "/F /IM evenly-tray.exe"; Flags: runhidden; RunOnceId: "KillTray"
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\evenly-apo.ps1"" -Action uninstall"; Check: EffectInstalled; Flags: runhidden waituntilterminated; RunOnceId: "RemoveEffect"; StatusMsg: "{cm:EffectOffStatus}"
Filename: "reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v Evenly /f"; Flags: runhidden; RunOnceId: "RemoveAutostart"

[Code]
function EffectInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{commonappdata}\Evenly\backup\state.json'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  rc: Integer;
  action: String;
begin
  if CurStep = ssInstall then
    Exec('taskkill.exe', '/F /IM evenly-tray.exe', '', SW_HIDE, ewWaitUntilTerminated, rc);
  if (CurStep = ssPostInstall) and (WizardIsTaskSelected('effect') or EffectInstalled) then
  begin
    if EffectInstalled then action := 'update' else action := 'install';
    WizardForm.StatusLabel.Caption := CustomMessage('EffectStatus');
    if not Exec('powershell.exe',
         '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\evenly-apo.ps1') + '" -Action ' + action +
         ' -Dll "' + ExpandConstant('{app}\evenly_apo.dll') + '"',
         '', SW_HIDE, ewWaitUntilTerminated, rc) then
      rc := -1;
    if rc <> 0 then
      SuppressibleMsgBox(FmtMessage(CustomMessage('EffectFailed'), [IntToStr(rc)]), mbInformation, MB_OK, IDOK);
  end;
end;
