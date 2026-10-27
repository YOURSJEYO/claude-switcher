# Isolated recovery boundaries: no real application, account, or system operation.
Add-CoreTest -Name 'committed recovery preserves an unverified active previous tree' -Tag Transaction -Body {
    . New-TransactionFixture
    $script:UnexpectedRecoveryCopy = ''
    function Invoke-TransactionCheckpoint {
        param([string]$Phase)
        if ($Phase -eq 'committed') {
            [IO.File]::WriteAllText((Join-Path "$script:DATA.previous" 'unexpected.txt'), 'unique unrelated recovery material')
            $script:UnexpectedRecoveryCopy = Join-Path "$script:DATA.previous" 'unexpected.txt'
            throw 'synthetic interrupt after unrelated material appears'
        }
    }
    $result = Invoke-AccountTransaction -Target B
    Assert-False $result.success 'interrupted transaction cannot report success'
    Assert-True $result.recoveryRequired 'unverified sidecar must require explicit recovery'
    Assert-True (Test-Path -LiteralPath $script:UnexpectedRecoveryCopy) 'cleanup cannot delete the unique unverified previous tree'
    Assert-Equal 'B' (Get-CurrentAccount) 'committed marker is retained, not guessed back to A'
    Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash
}

Add-CoreTest -Name 'committed recovery preserves an unverified previous account archive' -Tag Transaction -Body {
    . New-TransactionFixture
    function Invoke-TransactionCheckpoint {
        param([string]$Phase)
        if ($Phase -eq 'committed') {
            [IO.File]::WriteAllText((Join-Path "$script:BASE\accounts\A.previous" 'unexpected.txt'), 'unverified prior archive')
            throw 'synthetic interrupted archive cleanup'
        }
    }
    $result = Invoke-AccountTransaction -Target B
    Assert-False $result.success 'failure cannot turn into successful switch'
    Assert-True $result.recoveryRequired 'unverified archive must block future mutation'
    Assert-True (Test-Path -LiteralPath "$script:BASE\accounts\A.previous\unexpected.txt") 'unknown prior archive is retained'
    Assert-TransactionTree "$script:BASE\accounts\A" 'source-A' $script:TransactionSourceHash
    Assert-TransactionTree $script:DATA 'target-B' $script:TransactionTargetHash
}

Add-CoreTest -Name 'account transaction entry point acquires the shared operation lock' -Tag Transaction -Body {
    . New-TransactionFixture
    $held = Enter-OperationLock -WaitMilliseconds 100
    try {
        $result = Invoke-AccountTransaction -Target B -WaitMilliseconds 50
        Assert-False $result.success 'a direct transaction must not bypass a held operation lock'
        Assert-Equal 'busy' $result.code 'a locked transaction must expose a stable busy result'
        Assert-Equal 0 $script:TransactionCopyCalls 'a busy transaction must not copy account data'
        Assert-Equal 'source-A' ([IO.File]::ReadAllText((Join-Path $script:DATA 'identity.txt'))) 'a busy transaction must preserve active data'
    } finally { Exit-OperationLock -Handle $held }
}

Add-CoreTest -Name 'recovery entry point acquires the shared operation lock' -Tag Transaction -Body {
    New-TransactionFixture | Out-Null
    $journalPath = Join-Path $script:BASE 'transaction.json'
    [IO.File]::WriteAllText($journalPath, '{"schemaVersion":1,"operationId":"00000000-0000-0000-0000-000000000001","source":"A","target":"B","phase":"started","hadActive":true,"sourceManifest":[],"targetManifest":[]}')
    $before = [IO.File]::ReadAllText($journalPath)
    $held = Enter-OperationLock -WaitMilliseconds 100
    try {
        $result = Recover-PendingTransaction -WaitMilliseconds 50
        Assert-True $result.recoveryRequired 'recovery must be refused while another operation owns the lock'
        Assert-Equal 'busy' $result.code 'a locked recovery must expose a stable busy result'
        Assert-Equal $before ([IO.File]::ReadAllText($journalPath)) 'a busy recovery must preserve the transaction journal'
    } finally { Exit-OperationLock -Handle $held }
}
