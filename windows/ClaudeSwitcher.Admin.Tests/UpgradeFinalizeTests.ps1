# Isolated tests for upgrade-only template finalization. No installer, UAC, task, or installed state is touched.
$ErrorActionPreference = 'Stop'

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$installPath = Join-Path $repo 'windows\install.ps1'
. $installPath

$script:Passed = 0
$script:Failed = 0
$script:PayloadCalls = 0
$script:FakePayload = $null
$script:TemplateNames = @('claude-switch.ps1', 'SwitcherUI.ps1', 'claude-bodyguard.ps1')
$script:SnapshotNames = @($script:TemplateNames + 'version.txt')

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function Assert-TestEqual([object]$Expected, [object]$Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw ('ASSERT: ' + $Message + ' (expected=' + [string]$Expected + ', actual=' + [string]$Actual + ')')
    }
}

function Get-SetupProtectedPayload {
    $script:PayloadCalls++
    return $script:FakePayload
}

function New-TestWorkspace {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upgrade-finalize-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    return [IO.Path]::GetFullPath($root)
}

function New-TestFixture {
    param([string]$Root)
    $user = Join-Path $Root 'User'
    $appData = Join-Path $Root 'AppData'
    $temp = Join-Path $Root 'Temp'
    $appRoot = Join-Path $Root 'ProgramFiles\ClaudeSwitcher'
    $scripts = Join-Path $appRoot 'scripts'
    $base = Join-Path $user '.claude-switcher'
    $claude = Join-Path $appData 'Claude'
    foreach ($directory in @($user, $appData, $temp, $appRoot, $scripts, $base, (Join-Path $base 'accounts\A'), $claude)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    [IO.File]::WriteAllText((Join-Path $appRoot 'ClaudeSwitcher.exe'), 'synthetic-app', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'VERSION'), '2.0.0-test', [Text.UTF8Encoding]::new($false))
    foreach ($name in $script:TemplateNames) {
        [IO.File]::WriteAllText((Join-Path $scripts $name), ('new-' + $name), [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $base $name), ('old-' + $name), [Text.UTF8Encoding]::new($true))
    }
    [IO.File]::WriteAllText((Join-Path $base 'version.txt'), '1.0.0-old', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $base 'config.json'), '{"keep":"config"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $base 'accounts\A\snapshot.bin'), 'keep-account', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $claude 'session.json'), 'keep-claude', [Text.UTF8Encoding]::new($false))

    $script:FakePayload = [pscustomobject]@{
        App = Join-Path $appRoot 'ClaudeSwitcher.exe'
        Helper = Join-Path $appRoot 'helpers\ClaudeSwitcher.Admin.exe'
    }
    $script:SetupSourceDirectory = $scripts
    [pscustomobject]@{
        Root = $Root
        User = $user
        AppData = $appData
        Temp = $temp
        AppRoot = $appRoot
        Scripts = $scripts
        Base = $base
        Claude = $claude
    }
}

function Close-TestOperation([object]$Operation) {
    if ($null -ne $Operation) {
        Exit-UserSetupOperation -Handle $Operation.Handle -Lease $Operation.Lease
    }
}

function Invoke-IsolatedTest {
    param([string]$Name, [scriptblock]$Body)
    $root = New-TestWorkspace
    $saved = @{
        USERPROFILE = $env:USERPROFILE
        APPDATA = $env:APPDATA
        TEMP = $env:TEMP
        TMP = $env:TMP
    }
    try {
        $env:USERPROFILE = Join-Path $root 'User'
        $env:APPDATA = Join-Path $root 'AppData'
        $env:TEMP = Join-Path $root 'Temp'
        $env:TMP = Join-Path $root 'Temp'
        $script:PayloadCalls = 0
        $script:FakePayload = $null
        & $Body $root
        $script:Passed++
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:Failed++
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
        throw
    } finally {
        $env:USERPROFILE = $saved.USERPROFILE
        $env:APPDATA = $saved.APPDATA
        $env:TEMP = $saved.TEMP
        $env:TMP = $saved.TMP
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-IsolatedTest 'broker operation and snapshot signatures are exact' {
    param($root)
    $finalize = Get-Command Invoke-NativeUpgradeFinalize -ErrorAction Stop
    $snapshot = Get-Command New-NativeUpgradeSnapshot -ErrorAction Stop
    $restore = Get-Command Restore-NativeUpgradeSnapshot -ErrorAction Stop
    $remove = Get-Command Remove-NativeUpgradeSnapshot -ErrorAction Stop
    foreach ($pair in @(
        @($finalize, 'Operation'),
        @($snapshot, 'BasePath'),
        @($snapshot, 'Operation'),
        @($restore, 'Snapshot'),
        @($restore, 'Operation'),
        @($remove, 'Snapshot')
    )) {
        $command = $pair[0]
        $parameter = [string]$pair[1]
        Assert-Test ($command.Parameters.ContainsKey($parameter)) ($command.Name + ' must expose -' + $parameter)
        Assert-Test ([bool]$command.Parameters[$parameter].Attributes.Mandatory) ($command.Name + ' -' + $parameter + ' must be mandatory')
    }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'install.ps1 must parse'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    Assert-Test (-not ($parameterNames -contains 'FinalizeUpgrade')) 'public -FinalizeUpgrade CLI bypass must be removed'
}

Invoke-IsolatedTest 'finalize requires a snapshot prepared for the same operation' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test (-not $result.Result.success) 'finalize without a prepared snapshot must fail'
        Assert-TestEqual 'snapshot_required' $result.Result.code 'missing snapshot must have a stable code'
        Assert-TestEqual 'old-claude-switch.ps1' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'claude-switch.ps1'))) 'missing snapshot must not mutate templates'
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'finalize validates protected scripts source and preserves user data' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $snapshot = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test $snapshot.Result.success $snapshot.Result.message
        Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$snapshot.SnapshotPath)) 'snapshot must return a snapshot object with a path'
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test $result.Result.success $result.Result.message
        Assert-TestEqual 2 $script:PayloadCalls 'snapshot and finalize must each validate the protected payload'
        foreach ($name in $script:TemplateNames) {
            Assert-TestEqual ('new-' + $name) ([IO.File]::ReadAllText((Join-Path $fixture.Base $name))) ('template must update: ' + $name)
        }
        Assert-TestEqual '2.0.0-test' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'version.txt'))) 'version must update'
        Assert-TestEqual '{"keep":"config"}' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'config.json'))) 'config must be preserved'
        Assert-TestEqual 'keep-account' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'accounts\A\snapshot.bin'))) 'account data must be preserved'
        Assert-TestEqual 'keep-claude' ([IO.File]::ReadAllText((Join-Path $fixture.Claude 'session.json'))) 'Claude data must be preserved'
        Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$result.Result.snapshotPath)) 'successful finalize must return a snapshot path'
        $snapshotPath = [string]$snapshot.Result.snapshotPath
        $entries = @(Get-ChildItem -LiteralPath $snapshotPath -File -Force | Select-Object -ExpandProperty Name | Sort-Object)
        Assert-TestEqual (($script:SnapshotNames | Sort-Object) -join ',') ($entries -join ',') 'snapshot must contain only templates and version.txt'
        $cleanup = Remove-NativeUpgradeSnapshot -Snapshot $snapshot
        Assert-Test $cleanup.Result.success $cleanup.Result.message
        Assert-Test (-not (Test-Path -LiteralPath $snapshotPath)) 'snapshot cleanup must remove the unique temp directory'
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'finalize rejects a closed operation lock' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $operation.Handle.Dispose()
        $result = Invoke-NativeUpgradeFinalize -Operation $operation -BasePath $fixture.Base
        Assert-Test (-not $result.Result.success) 'closed lock must fail finalize'
        Assert-TestEqual 'operation_lock_not_held' $result.Result.code 'closed lock must have a stable code'
        Assert-TestEqual ('old-claude-switch.ps1') ([IO.File]::ReadAllText((Join-Path $fixture.Base 'claude-switch.ps1'))) 'closed lock must not mutate templates'
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'finalize rejects a missing active lease' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        [IO.File]::Delete((Join-Path $fixture.Base 'operation.lease.json'))
        $result = Invoke-NativeUpgradeFinalize -Operation $operation -BasePath $fixture.Base
        Assert-Test (-not $result.Result.success) 'missing lease must fail finalize'
        Assert-TestEqual 'operation_lease_inactive' $result.Result.code 'missing lease must have a stable code'
        Assert-TestEqual 'old-claude-switch.ps1' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'claude-switch.ps1'))) 'missing lease must not mutate templates'
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'finalize rejects a base path that is not the exact current user base' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $otherBase = Join-Path $root 'OtherUser\.claude-switcher'
        [void][IO.Directory]::CreateDirectory($otherBase)
        $result = Invoke-NativeUpgradeFinalize -Operation $operation -BasePath $otherBase
        Assert-Test (-not $result.Result.success) 'mismatched base path must fail finalize'
        Assert-TestEqual 'base_path_mismatch' $result.Result.code 'base path mismatch must have a stable code'
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'finalize rejects an install-root source and requires the installed scripts directory' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $snapshot = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test $snapshot.Result.success $snapshot.Result.message
        $script:SetupSourceDirectory = $fixture.AppRoot
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test (-not $result.Result.success) 'install-root source must fail finalize'
        Assert-TestEqual 'template_source_mismatch' $result.Result.code 'wrong source must have a stable code'
        [void](Remove-NativeUpgradeSnapshot -Snapshot $snapshot)
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'partial template copy is rolled back from the snapshot' {
    param($root)
    $fixture = New-TestFixture $root
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    $originalCopy = ${function:Copy-SetupUserTemplates}
    try {
        function Copy-SetupUserTemplates {
            param([string]$Destination)
            [IO.File]::WriteAllText((Join-Path $Destination 'claude-switch.ps1'), 'partial-new', [Text.UTF8Encoding]::new($true))
            throw 'synthetic copy failure'
        }
        $snapshot = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test $snapshot.Result.success $snapshot.Result.message
        $snapshotPath = [string]$snapshot.Result.snapshotPath
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test (-not $result.Result.success) 'partial copy must fail finalize'
        Assert-TestEqual 'upgrade_finalize_failed' $result.Result.code 'partial copy must return a stable failure code'
        Assert-TestEqual 'restored' $result.Result.restoreState 'internal restore must be recorded'
        Assert-Test (Test-Path -LiteralPath $snapshotPath) 'failed finalize must retain the snapshot for outer rollback'
        foreach ($name in $script:TemplateNames) {
            Assert-TestEqual ('old-' + $name) ([IO.File]::ReadAllText((Join-Path $fixture.Base $name))) ('rollback must restore: ' + $name)
        }
        Assert-TestEqual '1.0.0-old' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'version.txt'))) 'rollback must restore version'

        foreach ($name in $script:TemplateNames) {
            [IO.File]::WriteAllText((Join-Path $fixture.Base $name), ('outer-rollback-' + $name), [Text.UTF8Encoding]::new($true))
        }
        $repeatRestore = Restore-NativeUpgradeSnapshot -Snapshot $snapshot -Operation $operation
        Assert-Test $repeatRestore.Result.success $repeatRestore.Result.message
        foreach ($name in $script:TemplateNames) {
            Assert-TestEqual ('old-' + $name) ([IO.File]::ReadAllText((Join-Path $fixture.Base $name))) ('repeat restore must be safe: ' + $name)
        }
        $cleanup = Remove-NativeUpgradeSnapshot -Snapshot $snapshot
        Assert-Test $cleanup.Result.success $cleanup.Result.message
        Assert-Test (-not (Test-Path -LiteralPath $snapshotPath)) 'broker cleanup must remove the retained snapshot after outer rollback'
    } finally {
        ${function:Copy-SetupUserTemplates} = $originalCopy
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'restore removes a template that did not exist before finalize' {
    param($root)
    $fixture = New-TestFixture $root
    Remove-Item -LiteralPath (Join-Path $fixture.Base 'claude-bodyguard.ps1') -Force
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $snapshot = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test $snapshot.Result.success $snapshot.Result.message
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test $result.Result.success $result.Result.message
        Assert-Test (Test-Path -LiteralPath (Join-Path $fixture.Base 'claude-bodyguard.ps1')) 'finalize must create a missing template'
        $restore = Restore-NativeUpgradeSnapshot -Snapshot $snapshot -Operation $operation
        Assert-Test $restore.Result.success $restore.Result.message
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $fixture.Base 'claude-bodyguard.ps1'))) 'restore must remove a file absent at snapshot time'
        Assert-TestEqual '{"keep":"config"}' ([IO.File]::ReadAllText((Join-Path $fixture.Base 'config.json'))) 'restore must preserve config'
        $cleanup = Remove-NativeUpgradeSnapshot -Snapshot $snapshot
        Assert-Test $cleanup.Result.success $cleanup.Result.message
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'template scripts are copied but never executed' {
    param($root)
    $fixture = New-TestFixture $root
    $sentinel = Join-Path $root 'template-executed.txt'
    [IO.File]::WriteAllText((Join-Path $fixture.Scripts 'claude-switch.ps1'), ('Set-Content -LiteralPath ''' + $sentinel + ''' -Value executed'), [Text.UTF8Encoding]::new($true))
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $snapshot = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test $snapshot.Result.success $snapshot.Result.message
        $result = Invoke-NativeUpgradeFinalize -BasePath $fixture.Base -Operation $operation
        Assert-Test $result.Result.success $result.Result.message
        Assert-Test (-not (Test-Path -LiteralPath $sentinel)) 'template content must not execute during finalize'
        $cleanup = Remove-NativeUpgradeSnapshot -Snapshot $snapshot
        Assert-Test $cleanup.Result.success $cleanup.Result.message
    } finally {
        Close-TestOperation $operation
    }
}

Invoke-IsolatedTest 'cleanup rejects a directory outside the unique snapshot namespace' {
    param($root)
    $outside = Join-Path $root 'not-a-snapshot'
    [void][IO.Directory]::CreateDirectory($outside)
    $result = Remove-NativeUpgradeSnapshot -Snapshot $outside
    Assert-Test (-not $result.Result.success) 'outside snapshot path must fail cleanup'
    Assert-TestEqual 'unsafe_snapshot_path' $result.Result.code 'outside snapshot path must have a stable code'
    Assert-Test (Test-Path -LiteralPath $outside) 'outside directory must remain untouched'
}

Invoke-IsolatedTest 'snapshot rejects a reparse template before reading it' {
    param($root)
    $fixture = New-TestFixture $root
    $outside = Join-Path $root 'outside-template.ps1'
    [IO.File]::WriteAllText($outside, 'outside', [Text.UTF8Encoding]::new($false))
    $target = Join-Path $fixture.Base 'claude-switch.ps1'
    Remove-Item -LiteralPath $target -Force
    try {
        New-Item -ItemType SymbolicLink -Path $target -Target $outside -ErrorAction Stop | Out-Null
    } catch {
        Write-Host 'SKIP snapshot reparse test: symbolic links are unavailable in this host.'
        return
    }
    $operation = Enter-UserSetupOperation -BasePath $fixture.Base
    Assert-Test $operation.Success $operation.Error
    try {
        $result = New-NativeUpgradeSnapshot -BasePath $fixture.Base -Operation $operation
        Assert-Test (-not $result.Result.success) 'reparse target must fail snapshot'
    } finally {
        Close-TestOperation $operation
    }
    Assert-TestEqual 'unsafe_template_path' $result.Result.code 'reparse target must have a stable code'
    Assert-TestEqual 'outside' ([IO.File]::ReadAllText($outside)) 'outside file must remain unchanged'
}

if ($script:Failed -ne 0) {
    throw ('RESULT total={0} passed={1} failed={2}' -f ($script:Passed + $script:Failed), $script:Passed, $script:Failed)
}
Write-Host ('RESULT total={0} passed={0} failed=0' -f $script:Passed)