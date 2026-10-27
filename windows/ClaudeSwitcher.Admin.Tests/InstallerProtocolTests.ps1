# Isolated entry-point tests. Network, identity, protected payload, and UAC are replaced.
$ErrorActionPreference = 'Stop'
$taskRepo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:InnoTemplate = [IO.File]::ReadAllText((Join-Path $taskRepo 'windows/ClaudeSwitcher.iss'))
. (Join-Path $taskRepo 'windows/helpers/UserSetup.ps1')
$taskTokens = $null; $taskErrors = $null
$taskAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $taskRepo 'windows/install.ps1'), [ref]$taskTokens, [ref]$taskErrors)
if ($taskErrors.Count) { throw 'Installer must parse.' }
foreach ($taskFunction in $taskAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($taskFunction.Extent.Text))
}
if (-not (Get-Command Invoke-NativeUserSetupFlow -ErrorAction SilentlyContinue)) { throw 'ASSERT: installer must expose an isolated Preview/Apply flow.' }
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('switcher-install-flow-' + [guid]::NewGuid().ToString('N'))
$script:SetupSourceDirectory = Join-Path $script:TestRoot 'templates'
$script:SystemCalls = 0
$script:CancelSystem = $false
$script:ObservedCountry = 'JP'
$script:ElevatedIdentity = $false
$script:ProtectedPayloadAvailable = $true
$script:SetupOwnedTasks = @()
$script:OpenedSetupApp = $null
function Get-SetupIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=1; Elevated=$script:ElevatedIdentity } }
function Get-SetupEgress { [pscustomobject]@{ Country=$script:ObservedCountry; TimeZoneId='Tokyo Standard Time'; Culture='ja-JP' } }
function Get-SetupProtectedPayload {
    if (-not $script:ProtectedPayloadAvailable) { return $null }
    [pscustomobject]@{ Helper='C:\synthetic\ClaudeSwitcher.Admin.exe'; App='C:\synthetic\ClaudeSwitcher.exe' }
}
function Get-ScheduledTask { param($TaskPath,$ErrorAction) $script:SetupOwnedTasks }
function Start-Process { param($FilePath,$ArgumentList,$ErrorAction) $script:OpenedSetupApp=[pscustomobject]@{FilePath=$FilePath;Arguments=$ArgumentList} }
function Invoke-ElevatedSystemSetup {
    param($HelperPath,$Operation,$UserSid,$SessionId,$TimeZoneId)
    if ($Operation -notin @('repair-system','remove-bodyguard-task')) { throw 'Only closed repair/removal operations are allowed.' }
    $script:SystemCalls++
    $held = $false
    try { $other = [IO.File]::Open((Join-Path $script:ActiveBase 'operation.lock'), 'Open', 'ReadWrite', 'None'); $other.Dispose() }
    catch [IO.IOException] { $held = $true }
    if (-not $held) { throw 'Configuration and system stages must retain the same operation lock.' }
    if ($script:CancelSystem) { return New-UserSetupResult $false 'cancelled' @{Cancelled=$true;Retryable=$true} }
    return New-UserSetupResult $true
}
function New-Options {
    @{ NonInteractive=$true; ProxyMode='clash-verge'; ProxyGroup='Synthetic Group'; Preview=$false; Country='JP'; TimeZoneId='Tokyo Standard Time'; Culture='ja-JP' }
}
function Assert-Flow([bool]$condition,[string]$message) { if (-not $condition) { throw ('ASSERT: '+$message) } }

function Get-InnoSectionEntries {
    param([string]$Section)
    $pattern='(?ms)^\s*\['+[regex]::Escape($Section)+'\]\s*\r?\n(.*?)(?=^\s*\[|\z)'
    $match=[regex]::Match($script:InnoTemplate,$pattern)
    if (-not $match.Success) { throw ('ASSERT: missing Inno section ['+$Section+']') }
    return @($match.Groups[1].Value -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith(';') })
}

function Get-InnoFunction {
    param([string]$Name)
    $pattern='(?ms)^\s*function\s+'+[regex]::Escape($Name)+'\b[^\r\n]*\r?\n.*?(?=^\s*(?:function|procedure)\s+|\z)'
    $match=[regex]::Match($script:InnoTemplate,$pattern)
    if (-not $match.Success) { throw ('ASSERT: missing Inno function '+$Name) }
    return $match.Value
}
$script:Passed = 0
function Test-Flow([string]$name,[scriptblock]$body) {
    $script:ActiveBase = Join-Path $script:TestRoot ([guid]::NewGuid().ToString('N'))
    $script:SystemCalls=0; $script:CancelSystem=$false; $script:ObservedCountry='JP'; $script:ElevatedIdentity=$false; $script:ProtectedPayloadAvailable=$true
    $script:SetupOwnedTasks=@(); $script:OpenedSetupApp=$null
    & $body
    $script:Passed++
    Write-Host ('PASS '+$name)
}
New-Item -ItemType Directory -Force -Path $script:SetupSourceDirectory | Out-Null
foreach ($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1')) {
    [IO.File]::WriteAllText((Join-Path $script:SetupSourceDirectory $name), '# synthetic template', [Text.UTF8Encoding]::new($true))
}

try {
    Test-Flow 'Preview returns the exact reviewed fields without writes or UAC' {
        $o=New-Options; $o.Preview=$true; $o.Country=''; $o.TimeZoneId=''; $o.Culture=''
        $r=Invoke-NativeUserSetupFlow -Options $o -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -eq 0 -and $r.Result.country -eq 'JP') 'preview result'
        Assert-Flow (@($r.Result.PSObject.Properties).Count -eq 7) 'closed preview schema'
        Assert-Flow (-not (Test-Path -LiteralPath $script:ActiveBase)) 'preview must not write'
        Assert-Flow ($script:SystemCalls -eq 0) 'preview must not elevate'
    }
    Test-Flow 'Missing group fails before writes' {
        $o=New-Options; $o.ProxyGroup=''; $r=Invoke-NativeUserSetupFlow -Options $o -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $script:ActiveBase)) 'missing group must fail without writing'
    }
    Test-Flow 'CN and changed egress fail before writes' {
        foreach($country in @('CN','US')) {
            $script:ObservedCountry=$country; $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase
            Assert-Flow ($r.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $script:ActiveBase)) 'egress must match reviewed values'
        }
    }
    Test-Flow 'Elevated caller receives normal-user relaunch failure' {
        $script:ElevatedIdentity=$true; $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -ne 0 -and $r.Result.code -eq 'normal_user_required') 'must not initialize elevation account'
        Assert-Flow (-not (Test-Path -LiteralPath $script:ActiveBase)) 'identity must fail before writes'
    }
    Test-Flow 'Missing protected helper fails before user initialization' {
        $script:ProtectedPayloadAvailable=$false; $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $script:ActiveBase)) 'payload must validate before writes'
    }
    Test-Flow 'Apply copies templates and writes config under a held operation lock' {
        $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -eq 0 -and $r.Result.success -and $r.Result.stage -eq 'completed') 'completed requires all stages'
        Assert-Flow ($script:SystemCalls -eq 1) 'one UAC operation'
        Assert-Flow (Test-Path -LiteralPath (Join-Path $script:ActiveBase 'claude-switch.ps1')) 'user core must exist'
        $config=[IO.File]::ReadAllText((Join-Path $script:ActiveBase 'config.json')) | ConvertFrom-Json
        Assert-Flow ($config.country -eq 'JP') 'reviewed configuration must persist'
    }
    Test-Flow 'UAC cancellation preserves explicit system stage and exit four' {
        $script:CancelSystem=$true; $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -eq 4 -and -not $r.Result.success -and $r.Result.stage -eq 'system') 'cancellation is observable'
        Assert-Flow (Test-Path -LiteralPath (Join-Path $script:ActiveBase 'config.json')) 'preserve valid user stage for retry'
    }
    Test-Flow 'Held core operation lock blocks apply before config writes' {
        [void][IO.Directory]::CreateDirectory($script:ActiveBase)
        $lock=[IO.File]::Open((Join-Path $script:ActiveBase 'operation.lock'),'OpenOrCreate','ReadWrite','None')
        try { $r=Invoke-NativeUserSetupFlow -Options (New-Options) -BasePath $script:ActiveBase }
        finally { $lock.Dispose() }
        Assert-Flow ($r.ExitCode -ne 0 -and $script:SystemCalls -eq 0) 'busy core must block configuration'
        Assert-Flow (-not (Test-Path -LiteralPath (Join-Path $script:ActiveBase 'config.json'))) 'busy core config untouched'
    }
    Test-Flow 'Conflicting entry modes fail without launching or changing files' {
        foreach($flags in @(@{Initialize=$true;Preview=$true},@{Initialize=$true;RemoveUserTask=$true},@{RequireNoOtherTasks=$true})) {
            $o=New-Options
            foreach($key in $flags.Keys) { $o[$key]=$flags[$key] }
            $r=Invoke-NativeUserSetupFlow -Options $o -BasePath $script:ActiveBase
            Assert-Flow ($r.ExitCode -ne 0 -and $r.Result.code -eq 'invalid_entry_mode') 'conflicting flags must be rejected'
            Assert-Flow ($null -eq $script:OpenedSetupApp -and $script:SystemCalls -eq 0 -and -not (Test-Path -LiteralPath $script:ActiveBase)) 'invalid mode must have no effects'
        }
    }
    Test-Flow 'Initialize opens only the fixed app setup entry from a normal session' {
        $r=Invoke-NativeUserSetupFlow -Options @{Initialize=$true;NonInteractive=$true} -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -eq 0 -and $script:OpenedSetupApp.FilePath -eq 'C:\synthetic\ClaudeSwitcher.exe' -and $script:OpenedSetupApp.Arguments -eq '--setup') 'normal setup entry must be fixed'
        Assert-Flow (-not (Test-Path -LiteralPath $script:ActiveBase) -and $script:SystemCalls -eq 0) 'launch entry must not initialize or elevate'
        $script:ElevatedIdentity=$true; $script:OpenedSetupApp=$null
        $r=Invoke-NativeUserSetupFlow -Options @{Initialize=$true} -BasePath $script:ActiveBase
        Assert-Flow ($r.Result.code -eq 'normal_user_required' -and $null -eq $script:OpenedSetupApp) 'ambiguous elevated identity must relaunch from desktop'
    }
    Test-Flow 'Uninstall removal blocks other users tasks and does not invoke the helper' {
        $script:SetupOwnedTasks=@([pscustomobject]@{TaskName='ClaudeSwitcher.Bodyguard.S-1-5-21-1-2-3-1002'})
        $r=Invoke-NativeUserSetupFlow -Options @{RemoveUserTask=$true;RequireNoOtherTasks=$true;NonInteractive=$true} -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -ne 0 -and $r.Result.code -eq 'other_user_tasks_exist' -and $script:SystemCalls -eq 0) 'other SID must block uninstall'
        Assert-Flow (-not (Test-Path -LiteralPath $script:ActiveBase)) 'other users task inventory must not create user data'
    }
    Test-Flow 'Removal cancellation returns exit four while retaining user configuration' {
        [void][IO.Directory]::CreateDirectory($script:ActiveBase)
        $taskConfig=Join-Path $script:ActiveBase 'config.json'
        [IO.File]::WriteAllText($taskConfig,'synthetic-preserve')
        $script:CancelSystem=$true
        $r=Invoke-NativeUserSetupFlow -Options @{RemoveUserTask=$true;NonInteractive=$true} -BasePath $script:ActiveBase
        Assert-Flow ($r.ExitCode -eq 4 -and $r.Result.code -eq 'uac_cancelled' -and -not $r.Result.success) 'removal cancellation must retain retryable classification'
        Assert-Flow ([IO.File]::ReadAllText($taskConfig) -ceq 'synthetic-preserve') 'user configuration must survive removal failure'
    }
    Test-Flow 'existing native install is rejected before Files mutation' {
        $files=@(Get-InnoSectionEntries 'Files')
        Assert-Flow ($files.Count -eq 1) 'development Beta must stage only the normal app payload'
        Assert-Flow ($files[0] -match '^Source:\s*"\{#StageDir\}\\?\*";\s*DestDir:\s*"\{app\}";') 'only the app payload may be installed'
        $prepare=Get-InnoFunction 'PrepareToInstall'
        $detect=Get-InnoFunction 'ExistingNativeInstall'
        $initializeSetup=Get-InnoFunction 'InitializeSetup'
        Assert-Flow ($detect -match 'ClaudeSwitcher\.exe') 'existing install detection must include the native app executable'
        Assert-Flow ($detect -match 'RegQueryStringValue') 'existing install detection must include the uninstall registration'
        Assert-Flow ($detect -notmatch '\{app\}') 'early setup detection must not expand the app directory before it is initialized'
        Assert-Flow ($detect -match '\{autopf\}\\ClaudeSwitcher') 'early setup detection must use the fixed Program Files path'
        Assert-Flow ($initializeSetup -match 'Result\s*:=\s*not\s+ExistingNativeInstall') 'setup initialization must fail closed before any wizard or Files stage'
        Assert-Flow ($initializeSetup -match 'does not support safe in-place upgrades') 'setup initialization rejection must be explicit'
        $guardIndex=$prepare.IndexOf('if ExistingNativeInstall')
        $pathIndex=$prepare.IndexOf('CompareText')
        Assert-Flow ($guardIndex -ge 0 -and $pathIndex -gt $guardIndex) 'upgrade rejection must precede all other install checks'
        Assert-Flow ($prepare -match 'does not support safe in-place upgrades') 'upgrade rejection must be explicit'
        Assert-Flow ($prepare -notmatch '\bExtractTemporaryFile\s*\(') 'fail-closed development Beta must not claim an unimplemented lease'
    }
    Test-Flow 'new installation still installs the app and opens ordinary-user setup' {
        $run=@(Get-InnoSectionEntries 'Run')
        Assert-Flow ($run.Count -eq 1) 'new installation must retain one fixed setup entry'
        Assert-Flow ($run[0] -match '-Initialize') 'installed app must still open the configuration entry'
        Assert-Flow ($run[0] -match 'runasoriginaluser') 'post-install setup must not run as the elevated installer'
        Assert-Flow ($run[0] -match 'waituntilterminated') 'setup must observe the fixed entry result'
    }
    Test-Flow 'uninstall is rejected before any task or file mutation' {
        $initialize=Get-InnoFunction 'InitializeUninstall'
        Assert-Flow ($initialize -match '(?s)Result\s*:=\s*False;') 'uninstall must return false'
        Assert-Flow ($initialize -match 'Safe uninstall is not supported') 'uninstall refusal must be explicit'
        Assert-Flow ($initialize -match 'No scheduled tasks or program files were changed') 'uninstall refusal must state the no-mutation guarantee'
        Assert-Flow ($initialize -notmatch '\bExec\s*\(') 'uninstall refusal must not launch a task-removal helper'
        Assert-Flow ($initialize -notmatch '(?i)remove-bodyguard-task|-RemoveUserTask|DeleteFile|DelTree') 'uninstall refusal must not mutate tasks or files'
        Assert-Flow (-not ($script:InnoTemplate -match '(?im)^\s*\[Uninstall(?:Run|Delete)\]')) 'uninstaller must not declare deletion or run stages'
        Assert-Flow (-not ($script:InnoTemplate -match '(?i)operation-lease|OperationLease\.ps1')) 'development Beta must not advertise an unimplemented lease'
    }
    Write-Host ('RESULT total={0} passed={0} failed=0' -f $script:Passed)
} finally {
    $taskResolvedRoot=[IO.Path]::GetFullPath($script:TestRoot)
    if (-not $taskResolvedRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup target.' }
    Remove-Item -LiteralPath $taskResolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
}
