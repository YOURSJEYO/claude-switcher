# Isolated hard-crash transaction regressions. Dot-sourced by Invoke-CoreTests.ps1.
# Every child process uses fixture-only HOME/APPDATA and never touches installed core,
# real account data, Claude, network, or system settings.

function ConvertTo-CrashLiteral {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function New-CrashAccountTree {
    param([string]$Path, [string]$Identity, [byte[]]$Bytes)
    New-Item -ItemType Directory -Path (Join-Path $Path 'nested'), (Join-Path $Path 'empty') -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'identity.txt'), $Identity)
    [IO.File]::WriteAllBytes((Join-Path $Path 'nested\state.bin'), $Bytes)
}

function New-CrashFixture {
    $root = New-TestWorkspace
    $script:CrashRoot = $root
    $script:CrashHome = Join-Path $root 'home'
    $script:CrashAppData = Join-Path $root 'appdata'
    $script:CrashLocalAppData = Join-Path $root 'localappdata'
    $script:CrashTemp = Join-Path $root 'temp'
    $script:CrashBase = Join-Path $script:CrashHome '.claude-switcher'
    $script:CrashData = Join-Path $script:CrashAppData 'Claude'
    $script:CrashOperationId = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText((Join-Path $script:CrashBase 'current.txt'), 'A')
    New-CrashAccountTree $script:CrashData 'source-A' ([byte[]](1, 2, 3, 4))
    New-CrashAccountTree (Join-Path $script:CrashBase 'accounts\A') 'older-A' ([byte[]](5, 6, 7, 8))
    New-CrashAccountTree (Join-Path $script:CrashBase 'accounts\B') 'target-B' ([byte[]](9, 10, 11, 12))
    $script:CrashSourceHash = (Get-FileHash -LiteralPath (Join-Path $script:CrashData 'nested\state.bin') -Algorithm SHA256).Hash
    $script:CrashTargetHash = (Get-FileHash -LiteralPath (Join-Path $script:CrashBase 'accounts\B\nested\state.bin') -Algorithm SHA256).Hash
    $script:CrashArchiveHash = (Get-FileHash -LiteralPath (Join-Path $script:CrashBase 'accounts\A\nested\state.bin') -Algorithm SHA256).Hash
    return $root
}

function Get-CrashMarker {
    $path = Join-Path $script:CrashBase 'current.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'missing' }
    return ([IO.File]::ReadAllText($path)).Trim()
}

function Get-CrashOperationId {
    return $script:CrashOperationId
}

function Get-CrashBase {
    return $script:CrashBase
}

function Get-CrashRoot {
    return $script:CrashRoot
}

function Get-CrashData {
    return $script:CrashData
}

function Get-CrashSourceHash {
    return $script:CrashSourceHash
}

function Get-CrashTargetHash {
    return $script:CrashTargetHash
}

function Get-CrashArchiveHash {
    return $script:CrashArchiveHash
}

function Read-CrashJournal {
    $path = Join-Path $script:CrashBase 'transaction.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
}

function Assert-CrashTree {
    param([string]$Path, [string]$Identity, [string]$Hash)
    Assert-True (Test-Path -LiteralPath (Join-Path $Path 'identity.txt') -PathType Leaf) "complete identity exists at $Path"
    Assert-Equal $Identity ([IO.File]::ReadAllText((Join-Path $Path 'identity.txt'))) 'account identity remains intact'
    Assert-Equal $Hash (Get-FileHash -LiteralPath (Join-Path $Path 'nested\state.bin') -Algorithm SHA256).Hash 'binary content remains intact'
    Assert-True (Test-Path -LiteralPath (Join-Path $Path 'empty') -PathType Container) 'empty directories remain intact'
}

function Test-CrashCompleteSource {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Path 'identity.txt') -PathType Leaf)) { return $false }
        if ([IO.File]::ReadAllText((Join-Path $Path 'identity.txt')) -ne 'source-A') { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path $Path 'nested\state.bin') -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath (Join-Path $Path 'nested\state.bin') -Algorithm SHA256).Hash -ne $script:CrashSourceHash) { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path $Path 'empty') -PathType Container)) { return $false }
        return $true
    } catch { return $false }
}

function Assert-CrashCompleteSource {
    param([string]$Context)
    $candidates = @(
        $script:CrashData,
        "$script:CrashData.previous",
        (Join-Path $script:CrashBase 'accounts\A'),
        (Join-Path $script:CrashBase 'accounts\A.new'),
        (Join-Path $script:CrashBase 'accounts\A.previous')
    )
    $found = @($candidates | Where-Object { Test-CrashCompleteSource $_ })
    Assert-True ($found.Count -gt 0) "${Context}: at least one complete source tree must survive"
}

function Get-CrashCopyCount {
    $path = Join-Path $script:CrashRoot 'fakecopy.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
    return @([IO.File]::ReadAllLines($path)).Count
}

function Get-CrashTreeState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'MISSING' }
    $root = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName.TrimEnd([char]'\')
    $rows = New-Object 'Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($root.Length).TrimStart([char]'\')
        if ($item.PSIsContainer) { $rows.Add('D|' + $relative) }
        else { $rows.Add('F|' + $relative + '|' + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash) }
    }
    return ($rows -join "`n")
}

function Get-CrashMutationState {
    $parts = New-Object 'Collections.Generic.List[string]'
    foreach ($file in @('current.txt', 'transaction.json')) {
        $path = Join-Path $script:CrashBase $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { $parts.Add($file + '|' + [IO.File]::ReadAllText($path)) }
        else { $parts.Add($file + '|MISSING') }
    }
    $parts.Add('accounts|' + (Get-CrashTreeState (Join-Path $script:CrashBase 'accounts')))
    $parts.Add('data|' + (Get-CrashTreeState $script:CrashData))
    return ($parts -join "`n")
}
function Start-CrashProcess {
    param(
        [string]$Mode,
        [string]$Phase = '',
        [string]$OperationId = '',
        [string]$Root = ''
    )
    if (-not $Root) { $Root = $script:CrashRoot }
    $body = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'
$core = '__CORE__'
$mode = '__MODE__'
$crashAtPhase = '__PHASE__'
$crashOperationId = '__OPERATION_ID__'
. $core *> $null
$ErrorActionPreference = 'Stop'
function Invoke-AccountCopy {
    param([string]$Source, [string]$Destination)
    [IO.File]::AppendAllText((Join-Path $root 'fakecopy.log'), "$Source|$Destination`n")
    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
    return 0
}
function Invoke-TransactionCheckpoint {
    param([string]$Phase)
    if ($Phase -ceq $crashAtPhase) { [Environment]::Exit(77) }
}
function Test-LaunchGate { throw 'isolated crash test forbids launch gates' }
function Stop-ClaudeApp { throw 'isolated crash test forbids stopping Claude' }
function Start-ClaudeApp { throw 'isolated crash test forbids starting Claude' }
function Test-ProxyAlive { throw 'isolated crash test forbids proxy probes' }
function Get-TunStatus { throw 'isolated crash test forbids network adapter probes' }
function Get-Egress { throw 'isolated crash test forbids egress probes' }
function Get-StunAssessment { throw 'isolated crash test forbids STUN probes' }
function Get-StunPublicIP { throw 'isolated crash test forbids STUN probes' }
if ($mode -eq 'crash') {
    $null = Invoke-AccountTransaction -Target B -OperationId ([guid]$crashOperationId) -WaitMilliseconds 250
    exit 90
}
if ($mode -eq 'recover') {
    $result = Recover-PendingTransaction -WaitMilliseconds 250
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $root 'recovery.json') -Encoding UTF8
    exit 0
}
if ($mode -eq 'hold') {
    $handle = Enter-OperationLock -WaitMilliseconds 250
    if ($null -eq $handle) { exit 20 }
    try {
        [IO.File]::WriteAllText((Join-Path $root 'holder.ready'), 'locked')
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while (-not (Test-Path -LiteralPath (Join-Path $root 'release.signal'))) {
            if ([DateTime]::UtcNow -ge $deadline) { exit 21 }
            Start-Sleep -Milliseconds 25
        }
    } finally { Exit-OperationLock -Handle $handle }
    exit 0
}
if ($mode -eq 'contend-transaction' -or $mode -eq 'contend-recovery') {
    $result = if ($mode -eq 'contend-transaction') {
        Invoke-AccountTransaction -Target B -OperationId ([guid]$crashOperationId) -WaitMilliseconds 75
    } else {
        Recover-PendingTransaction -WaitMilliseconds 75
    }
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $root 'contender.json') -Encoding UTF8
    if ($result.code -ceq 'busy') { exit 0 }
    exit 22
}
exit 91
'@
    $body = $body.Replace('__ROOT__', (ConvertTo-CrashLiteral $Root))
    $body = $body.Replace('__CORE__', (ConvertTo-CrashLiteral $script:CorePath))
    $body = $body.Replace('__MODE__', (ConvertTo-CrashLiteral $Mode))
    $body = $body.Replace('__PHASE__', (ConvertTo-CrashLiteral $Phase))
    $body = $body.Replace('__OPERATION_ID__', (ConvertTo-CrashLiteral $OperationId))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['USERPROFILE'] = Join-Path $Root 'home'
    $info.EnvironmentVariables['HOME'] = Join-Path $Root 'home'
    $info.EnvironmentVariables['APPDATA'] = Join-Path $Root 'appdata'
    $info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Root 'localappdata'
    $info.EnvironmentVariables['TEMP'] = Join-Path $Root 'temp'
    $info.EnvironmentVariables['TMP'] = Join-Path $Root 'temp'
    New-Item -ItemType Directory -Path (Join-Path $Root 'temp') -Force -ErrorAction Stop | Out-Null
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $info
    if (-not $child.Start()) { throw 'ASSERT: isolated crash child failed to start' }
    return $child
}

function Complete-CrashProcess {
    param($Process, [string]$Context, [int]$ExpectedExitCode, [int]$TimeoutMilliseconds = 10000)
    try {
        Assert-True ($Process.WaitForExit($TimeoutMilliseconds)) "$Context must exit within $TimeoutMilliseconds ms"
        $stdout = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        Assert-Equal $ExpectedExitCode $Process.ExitCode ("$Context exit code; stdout=$stdout stderr=$stderr")
    } finally {
        if (-not $Process.HasExited) { $Process.Kill(); [void]$Process.WaitForExit(3000) }
        $Process.Dispose()
    }
}

function Assert-CrashJournalPhase {
    param([string]$Phase)
    $journal = Read-CrashJournal
    Assert-True ($null -ne $journal) "journal must exist at $Phase"
    Assert-Equal $Phase ([string]$journal.phase) "persisted journal phase at $Phase"
    Assert-Equal $script:CrashOperationId ([string]$journal.operationId) "journal operation id at $Phase"
}

function Assert-CrashPostRecovery {
    param([string]$Phase, [string]$CrashData, [string]$SourceHash, [string]$TargetHash, [string]$ArchiveHash)
    $marker = Get-CrashMarker
    if ($Phase -in @('committed', 'beforeCleanup', 'afterCleanup')) {
        Assert-Equal 'B' $marker "post-marker boundary $Phase retains target marker"
        Assert-CrashTree $CrashData 'target-B' $TargetHash
    } else {
        Assert-Equal 'A' $marker "pre-marker boundary $Phase restores source marker"
        Assert-CrashTree $CrashData 'source-A' $SourceHash
    }
    Assert-CrashCompleteSource $Phase
    if ($Phase -eq 'beforeArchiveBackup') {
        Assert-CrashTree (Join-Path (Get-CrashBase) 'accounts\A') 'older-A' $ArchiveHash
    }
}
$script:CrashCheckpointPhases = @(
    'beforeArchiveBackup',
    'afterArchiveBackup',
    'beforeArchivePromote',
    'afterArchivePromote',
    'beforeActiveBackup',
    'afterActiveBackup',
    'beforeTargetPromote',
    'afterTargetPromote',
    'beforeCleanup',
    'afterCleanup',
    'prepared',
    'activeReplaced',
    'committed'
)

function Add-CrashCheckpointTest {
    param([string]$CrashPhase)
    $body = {
        $phase = $CrashPhase
        New-CrashFixture | Out-Null
        $crashBase = Get-CrashBase
        $crashRoot = Get-CrashRoot
        $crashData = Get-CrashData
        $crashSourceHash = Get-CrashSourceHash
        $crashTargetHash = Get-CrashTargetHash
        $crashArchiveHash = Get-CrashArchiveHash
        $operationId = Get-CrashOperationId
        $crash = Start-CrashProcess -Mode crash -Phase $phase -OperationId $operationId
        Complete-CrashProcess -Process $crash -Context ("crash at {0}" -f $phase) -ExpectedExitCode 77
        $journalPath = Join-Path $crashBase 'transaction.json'
        if ($phase -eq 'afterCleanup') {
            Assert-False (Test-Path -LiteralPath $journalPath -PathType Leaf) 'hard crash after cleanup has already deleted the journal'
        } else {
            Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) ("hard crash at {0} leaves a journal" -f $phase)
            $journal = Read-CrashJournal
            Assert-Equal $operationId ([string]$journal.operationId) ("hard crash at {0} leaves the operation journal" -f $phase)
            Assert-True ($journal.phase -in @('started', 'archived', 'prepared', 'replacing', 'activeReplaced', 'committed')) ("hard crash at {0} leaves a valid recoverable phase" -f $phase)
        }
        $recovery = Start-CrashProcess -Mode recover -Root $crashRoot
        Complete-CrashProcess -Process $recovery -Context ("recovery after {0}" -f $phase) -ExpectedExitCode 0
        $resultPath = Join-Path $crashRoot 'recovery.json'
        Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) ("recovery after {0} returns structured JSON" -f $phase)
        $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -ErrorAction Stop
        Assert-True ($null -ne $result.success) ("recovery after {0} exposes success" -f $phase)
        if ($result.recoveryRequired) {
            Assert-False $result.success ("unresolved recovery after {0} is not success" -f $phase)
            $journalAfter = Read-CrashJournal
            Assert-True ($null -ne $journalAfter) ("unresolved recovery after {0} retains journal" -f $phase)
        } else {
            Assert-True $result.success ("resolved recovery after {0} reports success" -f $phase)
        }
        Assert-CrashPostRecovery $phase $crashData $crashSourceHash $crashTargetHash $crashArchiveHash
        $expectedCopies = if ($phase -in @(
            'beforeArchiveBackup',
            'afterArchiveBackup',
            'beforeArchivePromote',
            'afterArchivePromote'
        )) { 1 } else { 2 }
        Assert-Equal $expectedCopies (Get-CrashCopyCount) ("crash at {0} performs only the expected synthetic copies" -f $phase)
    }.GetNewClosure()
    Add-CoreTest -Tag Transaction -Name ("transaction hard crash at {0} recovers to a complete boundary state" -f $CrashPhase) -Body $body
}

foreach ($crashPhase in $script:CrashCheckpointPhases) {
    Add-CrashCheckpointTest -CrashPhase $crashPhase
}
Add-CoreTest -Tag Transaction -Name 'transaction crash at cleanup preserves an unknown sidecar exactly' -Body {
    New-CrashFixture | Out-Null
    $crash = Start-CrashProcess -Mode crash -Phase beforeCleanup -OperationId $script:CrashOperationId
    Complete-CrashProcess -Process $crash -Context 'cleanup crash fixture' -ExpectedExitCode 77
    $unknown = "$script:CrashData.previous\unknown-sidecar.txt"
    $unknownText = "unique unknown cleanup sidecar $([guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($unknown, $unknownText, (New-Object Text.UTF8Encoding $true))
    $before = Get-CrashTreeState "$script:CrashData.previous"
    $recovery = Start-CrashProcess -Mode recover -Root $script:CrashRoot
    Complete-CrashProcess -Process $recovery -Context 'recovery with unknown cleanup sidecar' -ExpectedExitCode 0
    $result = [IO.File]::ReadAllText((Join-Path $script:CrashRoot 'recovery.json')) | ConvertFrom-Json -ErrorAction Stop
    Assert-True $result.recoveryRequired 'unknown cleanup sidecar must block destructive recovery'
    Assert-False $result.success 'unknown cleanup sidecar cannot be reported as recovered success'
    Assert-Equal $before (Get-CrashTreeState "$script:CrashData.previous") 'recovery must not delete or alter the unknown sidecar tree'
    Assert-Equal $unknownText ([IO.File]::ReadAllText($unknown)) 'unique unknown sidecar content remains byte-for-byte intact'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:CrashBase 'transaction.json') -PathType Leaf) 'journal remains for explicit review'
}

Add-CoreTest -Tag Transaction -Name 'transaction public API contention is busy without mutation across two real processes' -Body {
    New-CrashFixture | Out-Null
    $holder = Start-CrashProcess -Mode hold -Root $script:CrashRoot
    $contender = $null
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while (-not (Test-Path -LiteralPath (Join-Path $script:CrashRoot 'holder.ready'))) {
            Assert-False $holder.HasExited 'lock holder exited before publishing readiness'
            if ([DateTime]::UtcNow -ge $deadline) { throw 'ASSERT: lock holder readiness timeout' }
            Start-Sleep -Milliseconds 25
        }
        $before = Get-CrashMutationState
        $contender = Start-CrashProcess -Mode contend-transaction -OperationId $script:CrashOperationId -Root $script:CrashRoot
        Complete-CrashProcess -Process $contender -Context 'transaction contender' -ExpectedExitCode 0 -TimeoutMilliseconds 5000
        $result = [IO.File]::ReadAllText((Join-Path $script:CrashRoot 'contender.json')) | ConvertFrom-Json -ErrorAction Stop
        Assert-False $result.success 'busy transaction cannot report success'
        Assert-False $result.recoveryRequired 'busy transaction is not a recovery result'
        Assert-Equal 'busy' ([string]$result.code) 'transaction public API returns stable busy code'
        Assert-Equal 0 (Get-CrashCopyCount) 'busy transaction performs no copy'
        Assert-Equal $before (Get-CrashMutationState) 'busy transaction mutates no account, marker, or journal state'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:CrashBase 'transaction.json')) 'busy transaction writes no journal'
        $recovery = Start-CrashProcess -Mode contend-recovery -Root $script:CrashRoot
        Complete-CrashProcess -Process $recovery -Context 'recovery contender' -ExpectedExitCode 0 -TimeoutMilliseconds 5000
        $recoveryResult = [IO.File]::ReadAllText((Join-Path $script:CrashRoot 'contender.json')) | ConvertFrom-Json -ErrorAction Stop
        Assert-False $recoveryResult.success 'busy recovery cannot report success'
        Assert-Equal 'busy' ([string]$recoveryResult.code) 'recovery public API returns stable busy code'
        Assert-Equal $before (Get-CrashMutationState) 'busy recovery mutates no account, marker, or journal state'
    } finally {
        [IO.File]::WriteAllText((Join-Path $script:CrashRoot 'release.signal'), 'release')
        if ($null -ne $holder) {
            try {
                if (-not $holder.HasExited) { Assert-True ($holder.WaitForExit(3000)) 'lock holder releases within 3s' }
            } catch {
                try { if (-not $holder.HasExited) { $holder.Kill() } } catch {}
            } finally { try { $holder.Dispose() } catch {} }
        }
        if ($null -ne $contender) {
            try { if (-not $contender.HasExited) { $contender.Kill() } } catch {}
            try { $contender.Dispose() } catch {}
        }
    }
}