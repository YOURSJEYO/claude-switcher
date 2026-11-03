# 验证 FlClash 直接返回的 DstPort 与 AND/DST-PORT 两种规则形式。
$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }
foreach ($name in @('CLAUDE_DOMAINS', 'CLAUDE_PORTS')) {
    $assignment = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq ('$' + $name)
    }, $true)
    if (-not $assignment) { throw "找不到 $name" }
    Invoke-Expression $assignment.Extent.Text
}
$fn = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-PinnedRules'
}, $true)
if (-not $fn) { throw '找不到 Test-PinnedRules' }
. ([scriptblock]::Create($fn.Extent.Text))
$domains = @($CLAUDE_DOMAINS | ForEach-Object {
    [pscustomobject]@{ type = 'DomainSuffix'; payload = $_ }
})
$directPorts = @($CLAUDE_PORTS | ForEach-Object {
    [pscustomobject]@{ type = 'DstPort'; payload = [string]$_ }
})
if (-not (Test-PinnedRules @($domains + $directPorts))) {
    throw 'FlClash 直接返回的 DstPort 未被识别'
}
'PASS 直接 DstPort 兼容'
$legacyPorts = @($CLAUDE_PORTS | ForEach-Object {
    [pscustomobject]@{ type = 'AND'; payload = "((Network,udp) && (DST-PORT,$_))" }
})
if (-not (Test-PinnedRules @($domains + $legacyPorts))) {
    $sample = $legacyPorts[0].payload
    $matchesPattern = $sample -match ('DST-PORT,(' + ($CLAUDE_PORTS -join '|') + ')(?:[,)]|$)')
    throw "AND/DST-PORT 形式未被识别: sample=$sample regex=$matchesPattern"
}
'PASS AND/DST-PORT 兼容'
