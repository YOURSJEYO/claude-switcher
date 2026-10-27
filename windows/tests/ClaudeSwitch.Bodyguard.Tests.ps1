Add-CoreTest -Tag Bodyguard -Name 'bodyguard exposes testable session-scoped process and heartbeat functions' {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 $errors.Count 'bodyguard remains valid PowerShell syntax'
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true).Name)
    foreach($name in @('Get-BodyguardIdentity','Get-OwnedClaudeProcesses','Write-BodyguardHeartbeat','Start-Bodyguard')) { Assert-True ($functions -contains $name) "required function $name exists" }
    Assert-True ($ast.Extent.Text -match "\`$MyInvocation\.InvocationName\s+-ne\s+'\.'") 'dot-sourcing for isolated tests cannot start the monitor loop'
}

Add-CoreTest -Tag Bodyguard -Name 'identity validation accepts supported user SID forms and rejects service or malformed SIDs' {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-BodyguardUserSid'},$false)
    Assert-True ($null -ne $function) 'pure SID validator must exist before testing'
    . ([scriptblock]::Create($function.Extent.Text))
    Assert-True (Test-BodyguardUserSid 'S-1-5-21-1-2-3-1001') 'domain/local user form accepted'
    Assert-True (Test-BodyguardUserSid 'S-1-12-1-1-2-3-4') 'cloud user form accepted'
    foreach($sid in @('S-1-5-18','S-1-5-21-1-2-3','S-1-12-1-1-2-3','not-a-sid','S-1-12-1-1-2-3-4;calc')) { Assert-False (Test-BodyguardUserSid $sid) 'invalid or service SID rejected' }
}

Add-CoreTest -Tag Bodyguard -Name 'bodyguard selects only Claude processes owned by its SID and session' {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    $script:BodyguardProcesses=@(
        [pscustomobject]@{ProcessId=11;SessionId=2;Name='Claude.exe'},
        [pscustomobject]@{ProcessId=12;SessionId=3;Name='Claude.exe'},
        [pscustomobject]@{ProcessId=13;SessionId=2;Name='Claude.exe'}
    )
    function Get-CimInstance { $script:BodyguardProcesses }
    function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid=if($InputObject.ProcessId -eq 13){'S-1-5-21-1-2-3-1002'}else{'S-1-5-21-1-2-3-1001'}} }
    function Get-Process { param([int]$Id) [pscustomobject]@{Id=$Id;SessionId=2;ProcessName='Claude'} }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnedClaudeProcesses'},$false)
    Assert-True ($null -ne $function) 'scoped selection function must exist before it can be invoked'
    . ([scriptblock]::Create($function.Extent.Text))
    $owned=@(Get-OwnedClaudeProcesses)
    Assert-Equal 1 $owned.Count 'other sessions and users are excluded'
    Assert-Equal 11 $owned[0].Id 'the current user process is retained'
}

Add-CoreTest -Tag Bodyguard -Name 'bodyguard owner lookup failure does not broaden to every Claude process' {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-CimInstance { [pscustomobject]@{ProcessId=11;SessionId=2;Name='Claude.exe'} }
    function Invoke-CimMethod { throw 'synthetic owner lookup failure' }
    function Get-Process { throw 'must not select an unverified process' }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnedClaudeProcesses'},$false)
    Assert-True ($null -ne $function) 'scoped selection function must exist before it can be invoked'
    . ([scriptblock]::Create($function.Extent.Text))
    $threw=$false
    try { $null=@(Get-OwnedClaudeProcesses) } catch { $threw=$true }
    Assert-True $threw 'uncertain ownership prevents process selection'
}

Add-CoreTest -Tag Bodyguard -Name 'bodyguard heartbeat carries caller SID session and process identity' {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-BodyguardProcessId { 321 }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-BodyguardHeartbeat'},$false)
    Assert-True ($null -ne $function) 'heartbeat function must exist before it can be invoked'
    . ([scriptblock]::Create($function.Extent.Text))
    $script:BodyguardBase=Join-Path $script:TestRoot 'synthetic-monitor'
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    Write-BodyguardHeartbeat
    $heartbeat=Get-Content -LiteralPath (Join-Path $script:BodyguardBase 'bodyguard-heartbeat.json') -Raw | ConvertFrom-Json
    Assert-Equal 1 $heartbeat.schemaVersion 'heartbeat schema is versioned'
    Assert-Equal 'S-1-5-21-1-2-3-1001' $heartbeat.userSid 'heartbeat is user-bound'
    Assert-Equal 2 $heartbeat.sessionId 'heartbeat is session-bound'
    Assert-Equal 321 $heartbeat.processId 'heartbeat identifies the monitor'
    if ($heartbeat.updatedAt -is [DateTime]) { $null=[DateTimeOffset]$heartbeat.updatedAt }
    else { $null=[DateTimeOffset]::ParseExact($heartbeat.updatedAt,'o',[Globalization.CultureInfo]::InvariantCulture) }
}

function Get-BodyguardFunctionAst([string]$Name) {
    $path=Join-Path (Split-Path $script:CorePath -Parent) 'claude-bodyguard.ps1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 $errors.Count 'bodyguard remains valid PowerShell syntax'
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$false)
    Assert-True ($null -ne $function) "required function $Name exists"
    return $function.Extent.Text
}

function New-BodyguardTestAcl([string]$Sid) {
    $owner=New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList $Sid
    $acl=[pscustomobject]@{OwnerSid=$owner}
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value {
        param($type) return $this.OwnerSid
    }
    return $acl
}

function Set-BodyguardTestFileOwner([string]$Sid) {
    $script:BodyguardTestOwner=$Sid
    return { function Get-Acl { New-BodyguardTestAcl $script:BodyguardTestOwner } }
}

function Assert-BodyguardRejected([scriptblock]$Body, [string]$ExpectedMessage, [string]$Message) {
    $errorText=$null
    try { & $Body } catch { $errorText=$_.Exception.Message }
    Assert-True ($null -ne $errorText) $Message
    Assert-Equal $ExpectedMessage $errorText $Message
}

Add-CoreTest -Tag Bodyguard -Name 'legacy proxy mode uses a bounded owner-checked leaf file' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('legacy-mode-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1001')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'sing-box')
    Assert-Equal 'sing-box' (Get-BodyguardProxyMode) 'valid legacy mode is accepted'
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'SING-BOX')
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid legacy monitor mode.' 'legacy mode comparison is case-sensitive'
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'auto ')
    Assert-Equal 'auto' (Get-BodyguardProxyMode) 'surrounding whitespace is trimmed'
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'other\nextra')
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid legacy monitor mode.' 'extra content is rejected'
}

Add-CoreTest -Tag Bodyguard -Name 'missing legacy proxy mode defaults without trusting a config file' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('missing-mode-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1001')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    Assert-Equal 'clash-verge' (Get-BodyguardProxyMode) 'missing legacy mode keeps old default'
}

Add-CoreTest -Tag Bodyguard -Name 'legacy mode rejects oversized directory and reparse files' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('legacy-shape-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1001')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    $path=Join-Path $script:BodyguardBase 'proxy-mode.txt'
    [IO.File]::WriteAllText($path,('x'*65))
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'oversized mode file is rejected'
    [IO.File]::Delete($path); [void][IO.Directory]::CreateDirectory($path)
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'directory at mode path is rejected'
    [void][IO.Directory]::Delete($path)
    [IO.File]::WriteAllText($path,'auto')
    $realGetItem=Get-Command Get-Item -CommandType Cmdlet
    function Get-Item { param($LiteralPath,$ErrorAction) [pscustomobject]@{PSIsContainer=$false;Length=4;Attributes=[IO.FileAttributes]::ReparsePoint} }
    try {
        Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'reparse mode file is rejected'
    } finally {
        Set-Item -Path 'Function:\Get-Item' -Value $realGetItem.ScriptBlock -ErrorAction SilentlyContinue
    }
}

Add-CoreTest -Tag Bodyguard -Name 'legacy mode rejects files owned by another user' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('legacy-owner-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1002')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'auto')
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'foreign-owned mode file is rejected'
}

Add-CoreTest -Tag Bodyguard -Name 'invalid native config never falls back to legacy mode' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('native-config-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1001')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'proxy-mode.txt'),'auto')
    [IO.File]::WriteAllText((Join-Path $script:BodyguardBase 'config.json'),'{"schemaVersion":1,"proxyMode":"SING-BOX"}')
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'invalid config is terminal rather than legacy fallback'
}

Add-CoreTest -Tag Bodyguard -Name 'native config rejects oversized directory reparse and foreign ownership' {
    $script:BodyguardBase=Join-Path $script:TestRoot ('native-shape-'+[guid]::NewGuid().Guid)
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    function Get-BodyguardIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1001')
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Read-BodyguardOwnedFile')))
    . ([scriptblock]::Create((Get-BodyguardFunctionAst 'Get-BodyguardProxyMode')))
    $path=Join-Path $script:BodyguardBase 'config.json'
    [IO.File]::WriteAllText($path,('x'*65537))
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'oversized config is rejected'
    [IO.File]::Delete($path); [void][IO.Directory]::CreateDirectory($path)
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'directory at config path is rejected'
    [void][IO.Directory]::Delete($path)
    [IO.File]::WriteAllText($path,'{"schemaVersion":1,"proxyMode":"auto"}')
    . (Set-BodyguardTestFileOwner 'S-1-5-21-1-2-3-1002')
    Assert-BodyguardRejected { Get-BodyguardProxyMode } 'Invalid monitor configuration.' 'foreign-owned config is rejected'
}