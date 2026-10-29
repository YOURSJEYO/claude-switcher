#ifndef AppVersion
  #error AppVersion must be supplied by scripts/package-windows.ps1
#endif
#ifndef AppFileVersion
  #error AppFileVersion must be supplied by scripts/package-windows.ps1
#endif
#ifndef StageDir
  #error StageDir must be supplied by scripts/package-windows.ps1
#endif
#ifndef OutputDir
  #error OutputDir must be supplied by scripts/package-windows.ps1
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename must be supplied by scripts/package-windows.ps1
#endif

[Setup]
AppId={{85E9726B-98E3-4CB8-B055-7E8A854D777B}
AppName=Claude Switcher
AppVersion={#AppVersion}
AppVerName=Claude Switcher {#AppVersion}
VersionInfoVersion={#AppFileVersion}
DefaultDirName={autopf}\ClaudeSwitcher
DisableDirPage=yes
UsePreviousAppDir=no
DefaultGroupName=Claude Switcher
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\ClaudeSwitcher.exe
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
Uninstallable=yes
LicenseFile={#StageDir}\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Claude Switcher"; Filename: "{app}\ClaudeSwitcher.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Claude Switcher"; Filename: "{app}\ClaudeSwitcher.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\scripts\install.ps1"" -Initialize -NonInteractive -Json"; Description: "Open Claude Switcher configuration"; Flags: postinstall skipifsilent runasoriginaluser waituntilterminated

[Code]
function ExistingNativeInstall(): Boolean;
var
  UninstallValue: String;
begin
  Result :=
    FileExists(ExpandConstant('{autopf}\ClaudeSwitcher\ClaudeSwitcher.exe')) or
    FileExists(ExpandConstant('{autopf}\ClaudeSwitcher\scripts\claude-switch.ps1'));

  if Result then
    exit;

  Result := RegQueryStringValue(
    HKLM,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1',
    'UninstallString',
    UninstallValue);
end;

function InitializeSetup(): Boolean;
begin
  Result := not ExistingNativeInstall;
  if not Result then
    MsgBox('Claude Switcher development Beta does not support safe in-place upgrades. No files were changed. Close Setup and keep using the existing installation.',
      mbError, MB_OK);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if ExistingNativeInstall then
  begin
    Result := 'Claude Switcher development Beta does not support safe in-place upgrades. No files were changed. Close Setup and keep using the existing installation.';
    exit;
  end;

  if CompareText(ExpandConstant('{app}'),
      ExpandConstant('{autopf}\ClaudeSwitcher')) <> 0 then
    Result := 'Claude Switcher must be installed in its fixed Program Files directory. Restart Setup without a custom /DIR option.';
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption +
      Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'Open Claude Switcher from your ordinary desktop session to complete configuration. If Setup was started from an elevated terminal, close it and use the Start menu shortcut.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := False;
  MsgBox('Safe uninstall is not supported by this development Beta. No scheduled tasks or program files were changed. User configuration and account data were preserved.',
    mbError, MB_OK);
end;
