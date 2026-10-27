# Dot-sourced by Invoke-CoreTests.ps1; no live account, network, or Claude operations.
# Copy/checkpoint hooks are replaced per fixture. The runner must restore core functions
# between tests, including Invoke-AccountCopy and Invoke-TransactionCheckpoint.

function Assert-TransactionAPI {
    param([string]$Name)
    Assert-True ($null -ne (Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue)) "Task2 API missing: $Name"
}

function New-TransactionFixture {
    Assert-TransactionAPI 'Invoke-AccountTransaction'
    $root = New-TestWorkspace
    $script:TransactionRoot = $root
    $script:TransactionCopyCodes = @(0, 0)
    $script:TransactionCopyCalls = 0
    $script:TransactionFailPhase = ''
    $script:TransactionPhases = @()
    $script:TransactionOperationId = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText((Join-Path $script:BASE 'current.txt'), 'A')
    foreach ($entry in @(
        @{ Path = $script:DATA; Identity = 'source-A'; Bytes = [byte[]](1, 2, 3, 4) },
        @{ Path = (Join-Path $script:BASE 'accounts\A'); Identity = 'older-A'; Bytes = [byte[]](5, 6, 7, 8) },
        @{ Path = (Join-Path $script:BASE 'accounts\B'); Identity = 'target-B'; Bytes = [byte[]](9, 10, 11, 12) }
    )) {
        New-Item -ItemType Directory -Path (Join-Path $entry.Path 'nested'), (Join-Path $entry.Path 'empty') -Force -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $entry.Path 'identity.txt'), $entry.Identity)
        [IO.File]::WriteAllBytes((Join-Path $entry.Path 'nested\state.bin'), $entry.Bytes)
    }
    $script:TransactionSourceHash = (Get-FileHash -LiteralPath (Join-Path $script:DATA 'nested\state.bin') -Algorithm SHA256).Hash
    $script:TransactionTargetHash = (Get-FileHash -LiteralPath (Join-Path $script:BASE 'accounts\B\nested\state.bin') -Algorithm SHA256).Hash
    function Invoke-AccountCopy {
        param([string]$Source, [string]$Destination)
        $index = $script:TransactionCopyCalls
        $script:TransactionCopyCalls++
        $code = if ($index -lt $script:TransactionCopyCodes.Count) { $script:TransactionCopyCodes[$index] } else { 0 }
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
        if ($code -ge 8) {
            [IO.File]::WriteAllText((Join-Path $Destination 'partial-copy.txt'), 'incomplete synthetic copy')
        } else {
            Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
            }
        }
        return [int]$code
    }
    function Invoke-TransactionCheckpoint {
        param([string]$Phase)
        $script:TransactionPhases += $Phase
        if ($Phase -eq $script:TransactionFailPhase) { throw "synthetic interruption: $Phase" }
    }
    function Test-LaunchGate { throw 'transaction must not run launch gates' }
    function Stop-ClaudeApp { throw 'transaction must not stop Claude' }
    function Start-ClaudeApp { throw 'transaction must not launch Claude' }
}

function Assert-TransactionTree {
    param([string]$Path, [string]$Identity, [string]$Hash)
    Assert-True (Test-Path -LiteralPath (Join-Path $Path 'identity.txt') -PathType Leaf) "complete identity exists at $Path"
    Assert-Equal $Identity ([IO.File]::ReadAllText((Join-Path $Path 'identity.txt'))) 'account identity remains intact'
    Assert-Equal $Hash (Get-FileHash -LiteralPath (Join-Path $Path 'nested\state.bin') -Algorithm SHA256).Hash 'binary content remains intact'
    Assert-True (Test-Path -LiteralPath (Join-Path $Path 'empty') -PathType Container) 'empty directories remain intact'
}

function Assert-TransactionState {
    param($Result)
    Assert-True ($null -ne $Result) 'structured result exists'
    foreach ($property in @('operationId', 'phase', 'current', 'success', 'recoveryRequired', 'code')) {
        Assert-True ($null -ne $Result.PSObject.Properties[$property]) "result includes $property"
    }
    Assert-True (@('idle', 'running', 'recoveryRequired', 'completed') -contains $Result.phase) 'public phase uses the agreed vocabulary'
    Assert-Equal $script:TransactionOperationId $Result.operationId 'operation identifier is preserved'
}

function Assert-TransactionInterruption {
    param([string]$Phase)
    . New-TransactionFixture
    Assert-TransactionAPI 'Recover-PendingTransaction'
    $script:TransactionFailPhase = $Phase
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-TransactionState $result
    Assert-True ($script:TransactionPhases -contains $Phase) "failure injection reaches $Phase"
    Assert-False $result.success 'injected failure must not report success'
    $verifiedSource = $false
    foreach ($path in @($script:DATA, "$script:DATA.previous", (Join-Path $script:BASE 'accounts\A'), (Join-Path $script:BASE 'accounts\A.new'), (Join-Path $script:BASE 'accounts\A.previous'))) {
        if (Test-Path -LiteralPath (Join-Path $path 'nested\state.bin')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $path 'nested\state.bin') -Algorithm SHA256).Hash
            if ($hash -eq $script:TransactionSourceHash -and (Test-Path -LiteralPath (Join-Path $path 'identity.txt')) -and [IO.File]::ReadAllText((Join-Path $path 'identity.txt')) -eq 'source-A') { $verifiedSource = $true }
        }
    }
    Assert-True $verifiedSource 'at least one verified complete source survives interruption'
    if ($Phase -eq 'committed') {
        Assert-Equal 'B' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'postcommit failure keeps the target marker'
        Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash
    } elseif (-not $result.recoveryRequired) {
        Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'recovered precommit failure keeps source marker'
        Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    }
    $script:TransactionFailPhase = ''
    $recovered = Recover-PendingTransaction
    Assert-True ($null -ne $recovered) 'recovery returns a structured result'
    if ($recovered.recoveryRequired) {
        $copies = $script:TransactionCopyCalls
        $blocked = Invoke-AccountTransaction -Target B -OperationId ([guid]::NewGuid().ToString())
        Assert-False $blocked.success 'unresolved recovery must block the next mutation'
        Assert-True $blocked.recoveryRequired 'unresolved recovery remains explicit'
        Assert-Equal $copies $script:TransactionCopyCalls 'blocked recovery must not perform another copy'
    } else {
        Assert-True $recovered.success 'resolved recovery reports success'
        $marker = [IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()
        Assert-Equal $marker $recovered.current 'recovery result matches persisted marker'
        if ($marker -eq 'A') { Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash }
        elseif ($marker -eq 'B') { Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash }
        else { throw 'ASSERT: recovery produced an unsupported marker' }
    }
}

Add-CoreTest -Tag Transaction -Name 'transaction source copy exit 8 preserves active data, marker and old archive' -Body {
    . New-TransactionFixture
    $script:TransactionCopyCodes = @(8)
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-TransactionState $result
    Assert-False $result.success 'exit 8 blocks source archival'
    Assert-Equal 1 $script:TransactionCopyCalls 'source failure must not copy target'
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'marker must not advance'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-Equal 'older-A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'accounts\A\identity.txt'))) 'previous archive must not be overwritten'
}

Add-CoreTest -Tag Transaction -Name 'transaction source copy exit 16 preserves source and refuses success' -Body {
    . New-TransactionFixture
    $script:TransactionCopyCodes = @(16)
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $result.success 'exit 16 blocks source archival'
    Assert-Equal 1 $script:TransactionCopyCalls 'source failure must stop immediately'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'marker remains A'
}

Add-CoreTest -Tag Transaction -Name 'transaction target copy exit 8 preserves active data and marker' -Body {
    . New-TransactionFixture
    $script:TransactionCopyCodes = @(0, 8)
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $result.success 'incomplete target must never commit'
    Assert-Equal 2 $script:TransactionCopyCalls 'failure is injected on target restore'
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'target failure preserves marker A'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-TransactionTree (Join-Path $script:BASE 'accounts\B') 'target-B' $script:TransactionTargetHash
}

Add-CoreTest -Tag Transaction -Name 'transaction exit 0 commits target and archives complete source' -Body {
    . New-TransactionFixture
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-TransactionState $result
    Assert-True $result.success 'copy exit 0 succeeds'
    Assert-False $result.recoveryRequired 'successful switch needs no recovery'
    Assert-Equal 'completed' $result.phase 'successful transaction is completed'
    Assert-Equal 'B' $result.current 'result reports B'
    Assert-Equal 'B' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'persisted marker reports B'
    Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash
    Assert-TransactionTree (Join-Path $script:BASE 'accounts\A') 'source-A' $script:TransactionSourceHash
}

Add-CoreTest -Tag Transaction -Name 'transaction exit 7 commits fully verified account contents' -Body {
    . New-TransactionFixture
    $script:TransactionCopyCodes = @(7, 7)
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-True $result.success 'robocopy exit 7 is successful'
    Assert-Equal 'B' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'exit 7 must commit marker'
    Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash
    Assert-TransactionTree (Join-Path $script:BASE 'accounts\A') 'source-A' $script:TransactionSourceHash
}

Add-CoreTest -Tag Transaction -Name 'transaction rejects same-size corrupt copy despite exit 0' -Body {
    . New-TransactionFixture
    function Invoke-AccountCopy {
        param([string]$Source, [string]$Destination)
        $script:TransactionCopyCalls++
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop }
        [IO.File]::WriteAllBytes((Join-Path $Destination 'nested\state.bin'), [byte[]](0, 0, 0, 0))
        return 0
    }
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $result.success 'successful copy exit alone cannot authorize corrupt data'
    Assert-Equal 1 $script:TransactionCopyCalls 'corrupt source-copy hook must actually be reached'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'hash mismatch must not advance marker'
}

Add-CoreTest -Tag Transaction -Name 'transaction prepared interruption restores source or explicitly requires recovery' -Body { Assert-TransactionInterruption 'prepared' }
Add-CoreTest -Tag Transaction -Name 'transaction activeReplaced interruption restores source or explicitly requires recovery' -Body { Assert-TransactionInterruption 'activeReplaced' }
Add-CoreTest -Tag Transaction -Name 'transaction committed interruption retains target and matching marker' -Body { Assert-TransactionInterruption 'committed' }

Add-CoreTest -Tag Transaction -Name 'transaction malformed journal blocks without deleting recovery data' -Body {
    . New-TransactionFixture
    Assert-TransactionAPI 'Recover-PendingTransaction'
    $journal = Join-Path $script:BASE 'transaction.json'
    [IO.File]::WriteAllText($journal, '{not valid json')
    New-Item -ItemType Directory -Path "$script:DATA.previous" -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path "$script:DATA.previous" 'unique.txt'), 'only copy')
    $result = Recover-PendingTransaction
    Assert-False $result.success 'malformed journal must fail closed'
    Assert-True $result.recoveryRequired 'malformed journal requires explicit recovery'
    $blocked = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $blocked.success 'new transaction must not bypass malformed journal'
    Assert-Equal 0 $script:TransactionCopyCalls 'malformed metadata cannot authorize copying'
    Assert-Equal '{not valid json' ([IO.File]::ReadAllText($journal)) 'malformed journal retained for diagnosis'
    Assert-Equal 'only copy' ([IO.File]::ReadAllText((Join-Path "$script:DATA.previous" 'unique.txt'))) 'unique recovery data retained'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
}

Add-CoreTest -Tag Transaction -Name 'transaction stale unsupported journal refuses destructive recovery' -Body {
    . New-TransactionFixture
    Assert-TransactionAPI 'Recover-PendingTransaction'
    $journal = Join-Path $script:BASE 'transaction.json'
    # Intentionally incomplete/stale schema, never a source of caller-selected paths.
    $stale = '{"version":0,"operationId":"00000000-0000-0000-0000-000000000000","current":"A","target":"B","phase":"unknown","createdUtc":"2000-01-01T00:00:00Z"}'
    [IO.File]::WriteAllText($journal, $stale)
    $result = Recover-PendingTransaction
    Assert-False $result.success 'stale unsupported metadata cannot authorize recovery'
    Assert-True $result.recoveryRequired 'unsupported journal requires intervention'
    $blocked = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $blocked.success 'new mutation must not bypass unsupported journal'
    Assert-Equal 0 $script:TransactionCopyCalls 'stale metadata must not authorize another copy'
    Assert-Equal $stale ([IO.File]::ReadAllText($journal)) 'unsupported journal is preserved'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'stale journal must not change marker'
}

Add-CoreTest -Tag Transaction -Name 'transaction unowned DATA.new and archive previous residues are never overwritten' -Body {
    foreach ($kind in @('active-new', 'archive-previous')) {
        . New-TransactionFixture
        $residue = if ($kind -eq 'active-new') { "$script:DATA.new" } else { Join-Path $script:BASE 'accounts\A.previous' }
        New-Item -ItemType Directory -Path $residue -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $residue 'unique.txt'), 'only surviving data')
        $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
        Assert-False $result.success 'unowned residue must block'
        Assert-True $result.recoveryRequired 'unowned residue must be explicit'
        Assert-Equal 0 $script:TransactionCopyCalls 'residue detection precedes copying'
        Assert-Equal 'only surviving data' ([IO.File]::ReadAllText((Join-Path $residue 'unique.txt'))) 'residue is not overwritten or removed'
        Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    }
}

Add-CoreTest -Tag Transaction -Name 'transaction copy filesystem exception fails closed with active source intact' -Body {
    . New-TransactionFixture
    function Invoke-AccountCopy { param($Source, $Destination) $script:TransactionCopyCalls++; throw [IO.IOException]::new('synthetic disk full') }
    $result = Invoke-AccountTransaction -Target B -OperationId $script:TransactionOperationId
    Assert-False $result.success 'disk/copy exception is observable failure'
    Assert-Equal 1 $script:TransactionCopyCalls 'disk failure injection must actually be reached'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $script:BASE 'current.txt')).Trim()) 'disk failure keeps source marker'
}

Add-CoreTest -Tag Transaction -Name 'transaction lock bounds contention and preserves lock filename on release' -Body {
    Assert-TransactionAPI 'Enter-OperationLock'
    Assert-TransactionAPI 'Exit-OperationLock'
    New-TestWorkspace | Out-Null
    $first = $null
    $second = $null
    try {
        $first = Enter-OperationLock -WaitMilliseconds 100
        Assert-True ($first -is [IO.FileStream]) 'exclusive lock returns its owned stream'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $second = Enter-OperationLock -WaitMilliseconds 100
        $timer.Stop()
        Assert-True ($null -eq $second) 'contender gets null rather than another lock'
        Assert-True ($timer.ElapsedMilliseconds -lt 3000) 'lock contention is bounded'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:BASE 'operation.lock')) 'stable per-user lock filename exists'
    } finally {
        if ($null -ne $second) { Exit-OperationLock -Handle $second }
        if ($null -ne $first) { Exit-OperationLock -Handle $first }
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $script:BASE 'operation.lock')) 'release must not unlink lock path'
    $third = Enter-OperationLock -WaitMilliseconds 100
    try { Assert-True ($third -is [IO.FileStream]) 'next owner can acquire after finally releases handle' }
    finally { if ($null -ne $third) { Exit-OperationLock -Handle $third } }
}

function Start-TransactionLockChild {
    param([string]$Root, [string]$Mode)
    $coreLiteral = $script:CorePath.Replace("'", "''")
    $rootLiteral = $Root.Replace("'", "''")
    $body = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'
. '__CORE__' *> $null
$handle = $null
try {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $handle = Enter-OperationLock -WaitMilliseconds 150
    $watch.Stop()
    if ('__MODE__' -eq 'holder') {
        if ($null -eq $handle) { exit 20 }
        [IO.File]::WriteAllText((Join-Path $root 'holder.ready'), 'locked')
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while (-not (Test-Path -LiteralPath (Join-Path $root 'release.signal'))) {
            if ([DateTime]::UtcNow -ge $deadline) { exit 21 }
            Start-Sleep -Milliseconds 25
        }
    } else {
        if ($null -ne $handle) { exit 22 }
        if ($watch.ElapsedMilliseconds -gt 3000) { exit 23 }
        [IO.File]::WriteAllText((Join-Path $root 'contender.busy'), 'busy')
    }
} finally { if ($null -ne $handle) { Exit-OperationLock -Handle $handle } }
exit 0
'@
    $body = $body.Replace('__ROOT__', $rootLiteral).Replace('__CORE__', $coreLiteral).Replace('__MODE__', $Mode)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($pair in @{
        USERPROFILE = (Join-Path $Root 'home'); HOME = (Join-Path $Root 'home');
        APPDATA = (Join-Path $Root 'appdata'); LOCALAPPDATA = (Join-Path $Root 'localappdata');
        TEMP = (Join-Path $Root 'temp'); TMP = (Join-Path $Root 'temp')
    }.GetEnumerator()) { $info.EnvironmentVariables[$pair.Key] = $pair.Value }
    New-Item -ItemType Directory -Path (Join-Path $Root 'temp') -Force -ErrorAction Stop | Out-Null
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $info
    if (-not $child.Start()) { throw 'ASSERT: isolated lock child failed to start' }
    return $child
}

Add-CoreTest -Tag Transaction -Name 'transaction two real PowerShell processes serialize the same synthetic user lock' -Body {
    Assert-TransactionAPI 'Enter-OperationLock'
    Assert-TransactionAPI 'Exit-OperationLock'
    $root = New-TestWorkspace
    $holder = $null
    $contender = $null
    try {
        $holder = Start-TransactionLockChild -Root $root -Mode holder
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while (-not (Test-Path -LiteralPath (Join-Path $root 'holder.ready'))) {
            if ($holder.HasExited) { throw ('ASSERT: holder exited early: ' + $holder.StandardError.ReadToEnd()) }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'ASSERT: holder ready timeout (6s)' }
            Start-Sleep -Milliseconds 25
        }
        $contender = Start-TransactionLockChild -Root $root -Mode contender
        Assert-True ($contender.WaitForExit(5000)) 'contending child must return busy within 5s'
        Assert-Equal 0 $contender.ExitCode ('contender exit: ' + $contender.StandardError.ReadToEnd())
        Assert-True (Test-Path -LiteralPath (Join-Path $root 'contender.busy')) 'second real process observes busy'
        [IO.File]::WriteAllText((Join-Path $root 'release.signal'), 'release')
        Assert-True ($holder.WaitForExit(3000)) 'holder releases within 3s'
        Assert-Equal 0 $holder.ExitCode ('holder exit: ' + $holder.StandardError.ReadToEnd())
        $handle = Enter-OperationLock -WaitMilliseconds 100
        try { Assert-True ($handle -is [IO.FileStream]) 'parent acquires only after holder exit' }
        finally { if ($null -ne $handle) { Exit-OperationLock -Handle $handle } }
    } finally {
        foreach ($child in @($contender, $holder)) {
            if ($null -ne $child) {
                if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(3000) }
                $child.Dispose()
            }
        }
    }
}
