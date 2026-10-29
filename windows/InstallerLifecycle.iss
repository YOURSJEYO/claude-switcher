// Included by ClaudeSwitcher.iss. Only fixed protected payload paths are mutated.
#define PayloadScriptHash GetSHA256OfFile(StageDir + "\helpers\InstallerPayload.ps1")

var
  WasInstalled, BrokerStarted, PayloadBackedUp, PayloadChanged: Boolean;
  MaintenanceComplete, CommitSent: Boolean;
  ContextDirectory, PayloadScript: String;
  ExpectedBrokerId: LongWord;
  PayloadExitCode: Integer;

function GetCurrentProcessId(): LongWord;
  external 'GetCurrentProcessId@kernel32.dll stdcall';

function GetTickCount(): LongWord;
  external 'GetTickCount@kernel32.dll stdcall';

function GetFileAttributes(const Path: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function OpenMaintenancePipe(const Name: String; Access, Share: LongWord;
  Security: Integer; Creation, Flags: LongWord; Template: Integer): THandle;
  external 'CreateFileW@kernel32.dll stdcall';
function SetPipeMode(Handle: THandle; var Mode: LongWord; Collection, Timeout: Integer): Boolean;
  external 'SetNamedPipeHandleState@kernel32.dll stdcall';
function WritePipe(Handle: THandle; const Data: AnsiString; Size: LongWord;
  var Written: LongWord; Overlapped: Integer): Boolean;
  external 'WriteFile@kernel32.dll stdcall';
function ReadPipe(Handle: THandle; var Data: LongWord; Size: LongWord;
  var ReadCount: LongWord; Overlapped: Integer): Boolean;
  external 'ReadFile@kernel32.dll stdcall';
function ClosePipe(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function GetPipeServerId(Handle: THandle; var ServerId: LongWord): Boolean;
  external 'GetNamedPipeServerProcessId@kernel32.dll stdcall';

function PipeRequest(const Command: String; var Response: LongWord): Boolean;
var
  Handle: THandle;
  Mode, Count, ServerId: LongWord;
  Index: Integer;
  Input: AnsiString;
begin
  Result := False;
  // SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION prevents impersonation
  // of this elevated installer by a user-mode pipe server.
  Handle := OpenMaintenancePipe('\\.\pipe\' + ExtractFileName(ContextDirectory),
    $C0000000, 0, 0, 3, $110000, 0);
  if Handle = THandle(-1) then exit;
  try
    if not GetPipeServerId(Handle, ServerId) or (ServerId <> ExpectedBrokerId) then exit;
    Mode := 1; // PIPE_NOWAIT; bound every read and write.
    if not SetPipeMode(Handle, Mode, 0, 0) then exit;
    Input := AnsiString(Command + '|' + ExtractFileName(ContextDirectory));
    Count := 0;
    for Index := 1 to 200 do
    begin
      if WritePipe(Handle, Input, Length(Input), Count, 0) and (Count = LongWord(Length(Input))) then break;
      Sleep(10);
    end;
    if Count <> LongWord(Length(Input)) then exit;
    for Index := 1 to 200 do
    begin
      if ReadPipe(Handle, Response, 4, Count, 0) and (Count = 4) then
      begin
        Result := True;
        exit;
      end;
      Sleep(10);
    end;
  finally
    ClosePipe(Handle);
  end;
end;

function ValidMaintenanceDirectory(const Directory: String): Boolean;
var
  Name: String;
  Index: Integer;
begin
  Result := False;
  // Only the pipe identifier is used; never write to an elevated user's TEMP.
  Name := ExtractFileName(Directory);
  if Pos('ClaudeSwitcher-maintenance-', Name) <> 1 then exit;
  if (Length(Name) < 40) or (Length(Name) > 128) then exit;
  for Index := 1 to Length(Name) do
    if Pos(Copy(Name, Index, 1), 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-') = 0 then exit;
  Result := True;
end;

function QuoteArg(const Value: String): String;
begin
  Result := '"' + Value + '"';
end;

function ExistingNativeInstall(): Boolean;
var
  Value: String;
begin
  Result := DirExists(ExpandConstant('{autopf}\ClaudeSwitcher')) or
    RegQueryStringValue(HKLM64,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1',
      'UninstallString', Value);
end;

function InitializeSetup(): Boolean;
begin
  WasInstalled := ExistingNativeInstall;
  Result := True;
  // An interrupted protected transaction needs explicit recovery, never deletion.
  if DirExists(ExpandConstant('{autopf}\ClaudeSwitcher.maintenance')) then
  begin
    Result := False;
    MsgBox('Previous maintenance requires recovery. Keep ClaudeSwitcher.maintenance and user data. No files were changed.', mbError, MB_OK);
  end;
end;

function IsNewInstall(): Boolean;
begin
  Result := not WasInstalled;
end;

function ReadMaintenanceState(): String;
var
  Response: LongWord;
begin
  Result := '';
  if not PipeRequest('status', Response) then exit;
  case Response of
    0: Result := 'starting';
    1: Result := 'ready';
    2: Result := 'prepared';
    3: Result := 'committed';
    4: Result := 'rolledback';
    5: Result := 'failed';
    6: Result := 'lost';
    7: Result := 'cleanup-failed';
  end;
end;

function WaitMaintenance(const Expected: String): Boolean;
var
  Index: Integer;
  State: String;
  Started: LongWord;
begin
  Result := False;
  Started := GetTickCount;
  for Index := 1 to 1500 do
  begin
    if GetTickCount - Started > 300000 then exit;
    State := ReadMaintenanceState();
    if State = Expected then
    begin
      Result := True;
      exit;
    end;
    if (State = 'lost') or ((State = 'failed') and (Expected <> 'rolledback')) or (State = 'cleanup-failed') then exit;
    Sleep(200);
  end;
end;

procedure SignalMaintenance(const Command: String);
var
  Ack: LongWord;
begin
  if not PipeRequest(Command, Ack) then
    RaiseException('Could not signal the user maintenance broker.');
  if Ack <> 100 then RaiseException('Invalid broker acknowledgement.');
end;

function RunPayload(const Mode: String): Boolean;
var
  ExitCode: Integer;
begin
  // Pin embedded code also at uninstall time, before elevated execution.
  Result := False;
  PayloadExitCode := -1;
  if CompareText(GetSHA256OfFile(PayloadScript), '{#PayloadScriptHash}') <> 0 then exit;
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + QuoteArg(PayloadScript) + ' -Mode ' + Mode,
    '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  if Result then
  begin
    PayloadExitCode := ExitCode;
    Result := ExitCode = 0;
  end;
  if not Result then Log('Protected payload operation ' + Mode + ' failed; stage code ' + IntToStr(PayloadExitCode));
end;

function StartMaintenanceBroker(): Boolean;
var
  ExitCode: Integer;
  Parameters, BrokerScript: String;
begin
  ExtractTemporaryFile('InstallerMaintenance.ps1');
  ExtractTemporaryFile('InstallerPayload.ps1');
  BrokerScript := ExpandConstant('{tmp}\InstallerMaintenance.ps1');
  PayloadScript := ExpandConstant('{tmp}\InstallerPayload.ps1');
  ContextDirectory := ExpandConstant('{tmp}\ClaudeSwitcher-maintenance-' + GetSHA256OfString(ExpandConstant('{tmp}')));
  ForceDirectories(ContextDirectory);
  Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + QuoteArg(BrokerScript) +
    ' -Mode SpawnBroker -Action upgrade -InstalledRoot ' + QuoteArg(ExpandConstant('{autopf}\ClaudeSwitcher')) +
    ' -ContextDirectory ' + QuoteArg(ContextDirectory) +
    ' -ParentProcessId ' + IntToStr(GetCurrentProcessId());
  Result := ExecAsOriginalUser(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ExitCode);
  if Result then
  begin
    if ExitCode <= 0 then begin Result := False; exit; end;
    ExpectedBrokerId := ExitCode;
    BrokerStarted := True;
    Result := WaitMaintenance('ready');
  end;
end;

procedure RollbackMaintenance();
begin
  // A sent commit is an irreversible decision. Lost acknowledgements retain
  // recovery material; they must never undo a possibly committed data cleanup.
  if not BrokerStarted or MaintenanceComplete or CommitSent then exit;
  if PayloadChanged then
  begin
    if not RunPayload('Restore') then
    begin
      MsgBox('Rollback could not be verified. Keep the protected maintenance copy and user recovery material.', mbError, MB_OK);
      exit;
    end;
    PayloadChanged := False;
  end;
  SignalMaintenance('rollback');
  if WaitMaintenance('rolledback') then
  begin
    if PayloadBackedUp and not RunPayload('Commit') then
      MsgBox('Rollback succeeded, but the maintenance backup could not be removed. Retain it for cleanup before the next Setup.', mbError, MB_OK);
    MaintenanceComplete := True;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if CompareText(ExpandConstant('{app}'), ExpandConstant('{autopf}\ClaudeSwitcher')) <> 0 then
  begin
    Result := 'Claude Switcher must be installed in its fixed Program Files directory. Restart Setup without a custom /DIR option.';
    exit;
  end;
  if not WasInstalled then exit;
  // Backup/rollback is coordinated while the broker owns operation.lock.
  if BrokerStarted then
  begin
    Result := 'Restart Setup after the current maintenance operation finishes.';
    exit;
  end;
  ExtractTemporaryFile('InstallerPayload.ps1');
  PayloadScript := ExpandConstant('{tmp}\InstallerPayload.ps1');
  if not RunPayload('Validate') then
  begin
    Result := 'Existing protected payload or recovery material could not be validated.';
    exit;
  end;
  if not StartMaintenanceBroker() then
  begin
    Result := 'Maintenance could not start. Exit Claude and Claude Switcher, and launch Setup from your ordinary desktop session. If recovery is reported, retain installer-maintenance.json and the lease; the guard may be stopped. Other configured users must remove their tasks first.';
    RollbackMaintenance();
    exit;
  end;
  if not RunPayload('Backup') then
  begin
    Result := 'A verified rollback copy could not be created (stage code ' + IntToStr(PayloadExitCode) + '). No program files were changed. Keep your existing data and review the Setup log.';
    RollbackMaintenance();
    exit;
  end;
  PayloadBackedUp := True;
end;

function RegisterUserUninstallLauncher(): Boolean;
var
  Key, Command: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1';
  Command := QuoteArg(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe')) +
    ' -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ' +
    QuoteArg(ExpandConstant('{autopf}\ClaudeSwitcher\helpers\InstallerMaintenance.ps1')) + ' -Mode LaunchUninstall';
  Result := RegWriteStringValue(HKLM64, Key, 'UninstallString', Command);
  if Result then Result := RegWriteStringValue(HKLM64, Key, 'QuietUninstallString', Command + ' -Quiet');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssInstall) and PayloadBackedUp then PayloadChanged := True;
  if CurStep = ssPostInstall then
  begin
    if BrokerStarted then
    begin
      SignalMaintenance('prepare');
      if not WaitMaintenance('prepared') then
      begin
        RollbackMaintenance();
        RaiseException('Upgrade preparation failed. Check the maintenance recovery material.');
      end;
    end;
    if not RegisterUserUninstallLauncher() then
    begin
      RollbackMaintenance();
      RaiseException('Could not register the user-context uninstall entry.');
    end;
    if BrokerStarted then
    begin
      CommitSent := True;
      SignalMaintenance('commit');
      if not WaitMaintenance('committed') then
        RaiseException('Maintenance commit was not acknowledged. Keep recovery material.');
      MaintenanceComplete := True;
      if not RunPayload('Commit') then
        MsgBox('Upgrade committed, but the protected maintenance backup needs cleanup before another Setup.', mbError, MB_OK);
    end;
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + Chr(13) + Chr(10) + Chr(13) + Chr(10) +
      'Open Claude Switcher from your ordinary desktop session. Upgrades preserve existing user configuration and account data.';
end;

procedure DeinitializeSetup();
begin
  RollbackMaintenance();
end;

function InitializeUninstall(): Boolean;
var
  Source: String;
begin
  // User data is preserved by default. Opt-in deletion is confirmed by the
  // non-elevated launcher, which keeps running after this uninstaller removes files.
  ContextDirectory := ExpandConstant('{param:MAINTENANCE|}');
  ExpectedBrokerId := StrToIntDef(ExpandConstant('{param:BROKERPID|0}'), 0);
  Result := True;
  if (ExpectedBrokerId = 0) or (ContextDirectory = '') or not ValidMaintenanceDirectory(ContextDirectory) then
  begin
    Result := False;
    MsgBox('Start uninstall using the Claude Switcher uninstall shortcut from your ordinary desktop session. User data is preserved by default.', mbError, MB_OK);
  end;
  if Result then
  begin
    BrokerStarted := True;
    if not WaitMaintenance('ready') then RaiseException('User maintenance lock was not acquired. Uninstall cancelled.');
    Source := ExpandConstant('{autopf}\ClaudeSwitcher\helpers\InstallerPayload.ps1');
    if CompareText(GetSHA256OfFile(Source), '{#PayloadScriptHash}') <> 0 then RaiseException('Uninstall payload script hash mismatch.');
    PayloadScript := ExpandConstant('{tmp}\InstallerPayload.ps1');
    if not FileCopy(Source, PayloadScript, False) then RaiseException('Could not stage protected uninstall code.');
    if not RunPayload('Verify') then RaiseException('The pre-launch uninstall rollback copy could not be verified.');
    PayloadBackedUp := True;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    PayloadChanged := True;
  end;
  if (CurUninstallStep = usPostUninstall) and BrokerStarted then
  begin
    SignalMaintenance('prepare');
    if not WaitMaintenance('prepared') then RaiseException('Uninstall preparation was not acknowledged.');
    CommitSent := True;
    SignalMaintenance('commit');
    if not WaitMaintenance('committed') then
    begin
      // Cleanup failure is different from program removal failure. Do not
      // resurrect program files after an optional, partially completed deletion.
      if ReadMaintenanceState() = 'cleanup-failed' then
      begin
        MaintenanceComplete := True;
        MsgBox('Program removed. Optional user-data cleanup did not finish; retained data needs manual review.', mbError, MB_OK);
      end
      else RaiseException('Uninstall commit could not be verified. Keep recovery material.');
    end
    else MaintenanceComplete := True;
    if MaintenanceComplete and not RunPayload('Commit') then
      MsgBox('Uninstall committed, but the protected maintenance backup needs manual cleanup.', mbError, MB_OK);
  end;
end;

procedure DeinitializeUninstall();
begin
  RollbackMaintenance();
end;
