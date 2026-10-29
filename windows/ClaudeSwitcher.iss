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
SetupMutex=Global\ClaudeSwitcher.Setup.Maintenance
CloseApplications=yes
CloseApplicationsFilter=ClaudeSwitcher.exe
RestartApplications=no
Uninstallable=yes
LicenseFile={#StageDir}\LICENSE

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\helpers\InstallerMaintenance.ps1"; DestDir: "{tmp}"; Flags: dontcopy
Source: "{#StageDir}\helpers\InstallerPayload.ps1"; DestDir: "{tmp}"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\Uninstall Claude Switcher"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\helpers\InstallerMaintenance.ps1"" -Mode LaunchUninstall"; WorkingDir: "{app}"
Name: "{autoprograms}\Claude Switcher"; Filename: "{app}\ClaudeSwitcher.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Claude Switcher"; Filename: "{app}\ClaudeSwitcher.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\scripts\install.ps1"" -Initialize -NonInteractive -Json"; Description: "Open Claude Switcher configuration"; Flags: postinstall skipifsilent runasoriginaluser waituntilterminated; Check: IsNewInstall

[Code]
#include "InstallerLifecycle.iss"
