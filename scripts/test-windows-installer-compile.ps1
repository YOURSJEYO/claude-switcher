# Compile the actual Inno/Pascal lifecycle without emitting or running an installer.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$IsccPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('claude-installer-compile-'+[guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'helpers'))
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $fixture 'LICENSE')
    foreach($name in @('InstallerMaintenance.ps1','InstallerPayload.ps1')){
        Copy-Item -LiteralPath (Join-Path $repo ('windows/helpers/'+$name)) -Destination (Join-Path $fixture ('helpers/'+$name))
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'ClaudeSwitcher.exe'),'synthetic non-executable payload')
    $arguments=@('/O-','/DAppVersion=0.0.0-compile','/DAppFileVersion=0.0.0.0',('/DStageDir='+$fixture),('/DOutputDir='+$fixture),'/DOutputBaseFilename=compiler-check',(Join-Path $repo 'windows/ClaudeSwitcher.iss'))
    & $IsccPath @arguments
    if($LASTEXITCODE -ne 0){throw 'The actual installer lifecycle did not compile.'}
    Write-Host 'Actual Inno lifecycle compiled successfully; no installer was emitted or executed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe compiler fixture cleanup.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
