# Isolated regression for the production client-language check. No account or network access.
# Run with Windows PowerShell 5.1 or pwsh 7.
$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cs-language-it-' + [guid]::NewGuid().ToString('N'))
$savedEnv = @{}
foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')) {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, (Join-Path $root $name))
}
$savedUICulture = [Threading.Thread]::CurrentThread.CurrentUICulture
$script:appxPackage = [pscustomobject]@{ PackageFamilyName = 'Claude_test_pfn' }
function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name)
    $script:appxPackage
}
function Write-Config([string]$path, [string]$json) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}
function Assert-Result([string]$name, [string]$pattern) {
    $result = @(& $languageCheck)
    if ($result.Count -ne 1 -or $result[0] -notmatch $pattern) { throw "$name : $result" }
    "PASS $name"
}
try {
    foreach ($name in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA')) {
        New-Item -ItemType Directory -Path ([Environment]::GetEnvironmentVariable($name)) -Force | Out-Null
    }
    . $core *> $null
    $ErrorActionPreference = 'Stop'
    $script:CheckConfig = $null
    $LOCALE_TARGET = 'en-US'
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('zh-CN')
    $ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CheckDetail' }, $true)
    $check = $fn.Body.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq "Test-CheckDisabled '客户端语言'"
    }
    if (-not $check) { throw 'Production language check not found' }
    $languageCheck = [scriptblock]::Create($check.Extent.Text)
    $legacyData = Join-Path $env:APPDATA 'Claude'
    $legacyConfig = Join-Path $legacyData 'config.json'
    $msixData = Join-Path $env:LOCALAPPDATA 'Claude-Data\Claude_test_pfn'
    $msixConfig = Join-Path $msixData 'config.json'
    Write-Config $msixConfig '{"locale":"en-US"}'
    Write-Config (Join-Path $legacyData 'claude_desktop_config.json') '{}'
    $DATA = Find-ClaudeDataPath
    if ($DATA -ne $legacyData) { throw 'Account data-directory priority changed' }
    Assert-Result 'MSIX config with legacy MCP-only directory and Chinese Windows UI' '^客户端语言=ok:Claude=en-US$'
    Write-Config $legacyConfig '{"locale":"zh-CN"}'
    Assert-Result 'Existing legacy locale is authoritative' '^客户端语言=warn:Claude=zh-CN,期望 en 前缀$'
    Write-Config $legacyConfig '{"locale":"en-GB"}'
    Assert-Result 'Matching language prefix' '^客户端语言=ok:Claude=en-GB$'
    foreach ($json in @('{', '{}', '{"locale":""}', '{"locale":false}', '{"locale":["en-US"]}', '{"locale":{"name":"en-US"}}', '{"locale":"en-US\n"}')) {
        Write-Config $legacyConfig $json
        Assert-Result 'Malformed or missing locale stays unknown without MSIX fallback' '^客户端语言=warn:未能读取 Claude 的语言设置$'
    }
    Remove-Item -LiteralPath $legacyConfig -Force
    Remove-Item -LiteralPath $msixConfig -Force
    Assert-Result 'Missing config stays unknown' '^客户端语言=warn:未能读取 Claude 的语言设置$'
    $script:appxPackage = $null
    $otherMsix = Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_other_pfn'
    Write-Config (Join-Path $otherMsix 'config.json') '{"locale":"en-US"}'
    Assert-Result 'Multiple unowned MSIX directories are not guessed' '^客户端语言=warn:未能读取 Claude 的语言设置$'
    $script:CheckConfig = [pscustomobject]@{ disabled = @('客户端语言'); allowOptionalFailures = $false }
    $script:readCount = 0
    function Get-Content { $script:readCount++; throw 'Disabled check must not read config' }
    Assert-Result 'Disabled check reports skip' '^客户端语言=skip:'
    if ($script:readCount -ne 0) { throw 'Disabled check read config' }
} finally {
    [Threading.Thread]::CurrentThread.CurrentUICulture = $savedUICulture
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    if (Test-Path -LiteralPath $root) {
        $resolvedRoot = (Resolve-Path -LiteralPath $root).Path
        if ($resolvedRoot -ne [IO.Path]::GetFullPath($root)) { throw 'Unexpected temporary cleanup path' }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
