[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDirectory,
    [string]$RepoRoot,
    [string]$DotnetPath,
    [string]$IsccPath,
    [string]$GitPath,
    [string]$PowerShell7Path,
    [scriptblock]$ProcessRunner
)

$script:PackageRuntime = 'win-x64'
$script:PackageToolVersion = '10.0.403'
$script:InnoToolVersion = '6.7.3'
$script:PackageLibraryMode = $MyInvocation.InvocationName -eq '.'

function New-PackageFailure {
    param([string]$Message)
    return [InvalidOperationException]::new($Message)
}
function Assert-ProductionMode {
    param([scriptblock]$ProcessRunner, [bool]$LibraryMode)
    if (-not $LibraryMode -and $null -ne $ProcessRunner) {
        throw (New-PackageFailure 'ProcessRunner is a test-only hook and is not accepted in production packaging mode.')
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            [void]$builder.Append('\', (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append('\', $backslashes); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append('\', ($backslashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-CanonicalFullPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$BaseDirectory)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BaseDirectory $Path }
    return [IO.Path]::GetFullPath($candidate)
}

function Assert-PathWithin {
    param([string]$Path, [string]$Root, [string]$Description)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($fullPath.Equals($fullRoot, $comparison)) { return $fullPath }
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) {
        throw (New-PackageFailure "$Description escapes the allowed root: $Path")
    }
    return $fullPath
}

function Get-SafeReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw (New-PackageFailure 'Version is required.') }
    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*))?$') {
        throw (New-PackageFailure "Unsafe version '$Value'; expected x.y.z with an optional simple suffix.")
    }
    $parts = @($Matches[1], $Matches[2], $Matches[3] | ForEach-Object { [int]$_ })
    foreach ($part in $parts) {
        if ($part -gt 65535) { throw (New-PackageFailure "Version component '$part' exceeds the installer limit of 65535.") }
    }
    $suffix = $Matches[4]
    $suffixNumber = 0
    if (-not [string]::IsNullOrWhiteSpace($suffix)) {
        $numericTokens = @([regex]::Matches($suffix, '[0-9]+') | ForEach-Object { $_.Value })
        if ($numericTokens.Count -gt 0) { $suffixNumber = [int]$numericTokens[-1] }
        if ($suffixNumber -gt 65535) { throw (New-PackageFailure 'Suffix numeric token exceeds the installer limit of 65535.') }
    }
    return [pscustomobject][ordered]@{
        Version = $Value
        InstallerVersion = ('{0}.{1}.{2}.{3}' -f $parts[0], $parts[1], $parts[2], $suffixNumber)
    }
}

function Assert-DotnetPin {
    param([string]$RepoRoot, [string]$DotnetPath, [scriptblock]$Runner)
    $globalJsonPath = Join-Path $RepoRoot 'global.json'
    if (-not (Test-Path -LiteralPath $globalJsonPath -PathType Leaf)) { throw (New-PackageFailure 'global.json is required to pin the .NET SDK.') }
    try { $global = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json }
    catch { throw (New-PackageFailure 'global.json is not valid JSON.') }
    if (-not $global.sdk -or -not $global.sdk.version) { throw (New-PackageFailure 'global.json must pin sdk.version.') }
    $pinned = [string]$global.sdk.version
    if ($pinned -notmatch '^10\.0\.[0-9]+$') { throw (New-PackageFailure "Unsupported .NET SDK pin '$pinned'; .NET 10 is required.") }
    if ([string]$global.sdk.rollForward -ne 'disable') { throw (New-PackageFailure 'global.json must set rollForward to disable.') }
    if ([string]$global.sdk.version -ne $script:PackageToolVersion) { throw (New-PackageFailure "global.json pins '$pinned' but packaging requires '$script:PackageToolVersion'.") }
    $result = Invoke-PackageProcess -Spec ([pscustomobject]@{ FilePath = $DotnetPath; Arguments = @('--version'); WorkingDirectory = $RepoRoot; TimeoutSeconds = 60 }) -Runner $Runner
    if ($result.ExitCode -ne 0) { throw (New-PackageFailure 'Unable to query the selected dotnet SDK version.') }
    if (([string]$result.StdOut).Trim() -ne $pinned) { throw (New-PackageFailure "dotnet reports '$(([string]$result.StdOut).Trim())' but global.json pins '$pinned'.") }
}

function Assert-RequiredFile {
    param([string]$RepoRoot, [string]$RelativePath, [string]$Description)
    $path = Assert-PathWithin (Join-Path $RepoRoot $RelativePath) $RepoRoot "$Description path"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-PackageFailure "Required $Description is missing: $RelativePath") }
    return $path
}

function Assert-RequiredDirectory {
    param([string]$RepoRoot, [string]$RelativePath, [string]$Description)
    $path = Assert-PathWithin (Join-Path $RepoRoot $RelativePath) $RepoRoot "$Description path"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw (New-PackageFailure "Required $Description is missing: $RelativePath") }
    return $path
}

function Get-RequiredPackageInputs {
    param([string]$RepoRoot)
    $files = [ordered]@{}
    foreach ($item in @(
        @{ Key = 'GlobalJson'; Path = 'global.json'; Label = 'SDK pin' },
        @{ Key = 'InnoTemplate'; Path = 'windows/ClaudeSwitcher.iss'; Label = 'Inno Setup template' },
        @{ Key = 'AppProject'; Path = 'windows/ClaudeSwitcher.App/ClaudeSwitcher.App.csproj'; Label = 'WPF application project' },
        @{ Key = 'AppTests'; Path = 'windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj'; Label = 'WPF test project' },
        @{ Key = 'AdminProject'; Path = 'windows/ClaudeSwitcher.Admin/ClaudeSwitcher.Admin.csproj'; Label = 'admin project' },
        @{ Key = 'AdminTests'; Path = 'windows/ClaudeSwitcher.Admin.Tests/ClaudeSwitcher.Admin.Tests.csproj'; Label = 'admin test project' },
        @{ Key = 'CoreRunner'; Path = 'windows/tests/Invoke-CoreTests.ps1'; Label = 'PowerShell core test runner' },
        @{ Key = 'UserSetupTests'; Path = 'windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1'; Label = 'isolated user setup tests' },
        @{ Key = 'InstallerProtocolTests'; Path = 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1'; Label = 'isolated installer protocol tests' },
        @{ Key = 'License'; Path = 'LICENSE'; Label = 'project license' }
    )) {
        $files[$item.Key] = Assert-RequiredFile $RepoRoot $item.Path $item.Label
    }
    $helperDirectory = Assert-RequiredDirectory $RepoRoot 'windows/helpers' 'installer helper payload directory'
    $helperFiles = @(Get-ChildItem -LiteralPath $helperDirectory -Recurse -File -Force | Sort-Object FullName)
    if ($helperFiles.Count -eq 0) { throw (New-PackageFailure 'Required installer helper payload directory is empty: windows/helpers') }
    return [pscustomobject]@{ Files = $files; HelperDirectory = $helperDirectory; HelperFiles = $helperFiles }
}

function Resolve-PackageTool {
    param([string]$ExplicitPath, [string]$RepoRoot, [string[]]$Candidates, [string]$Label)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $path = Get-CanonicalFullPath $ExplicitPath $RepoRoot
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-PackageFailure "$Label tool not found: $ExplicitPath") }
        return $path
    }
    foreach ($candidate in $Candidates) {
        $path = Get-CanonicalFullPath $candidate $RepoRoot
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $command = Get-Command $Candidates[0] -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.CommandType -ne 'Application') { $command = $null }
    if ($command) { return $command.Source }
    throw (New-PackageFailure "$Label tool not found. Pass its fixed executable path explicitly.")
}

function Get-PackageTools {
    param([string]$RepoRoot, [string]$DotnetPath, [string]$IsccPath, [string]$GitPath, [string]$PowerShell7Path)
    $dotnetCandidates = if ($DotnetPath) { @($DotnetPath) } else { @('build/tools/dotnet/dotnet.exe', 'dotnet.exe') }
    $isccCandidates = if ($IsccPath) { @($IsccPath) } else {
        @(
            'build/tools/innosetup/ISCC.exe',
            'build/tools/Inno Setup 6/ISCC.exe',
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe',
            'ISCC.exe'
        )
    }
    $gitCandidates = if ($GitPath) { @($GitPath) } else { @('git.exe') }
    $systemPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) { throw (New-PackageFailure 'Windows PowerShell 5.1 executable not found.') }
    $pwsh = $null
    if (-not [string]::IsNullOrWhiteSpace($PowerShell7Path)) {
        $pwsh = Get-CanonicalFullPath $PowerShell7Path $RepoRoot
        if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw (New-PackageFailure "pwsh tool not found: $PowerShell7Path") }
    } else {
        $pwshCommand = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwshCommand) { $pwsh = $pwshCommand.Source }
    }
    return [pscustomobject]@{
        Dotnet = Resolve-PackageTool $DotnetPath $RepoRoot $dotnetCandidates '.NET SDK'
        Iscc = Resolve-PackageTool $IsccPath $RepoRoot $isccCandidates 'Inno Setup'
        Git = Resolve-PackageTool $GitPath $RepoRoot $gitCandidates 'Git'
        SystemPowerShell = $systemPowerShell
        PowerShell7 = $pwsh
    }
}

function Invoke-PackageProcess {
    param([Parameter(Mandatory = $true)]$Spec, [scriptblock]$Runner)
    if ($Runner) {
        $result = & $Runner $Spec
        if ($null -eq $result) { throw (New-PackageFailure "Process hook returned no result for $($Spec.FilePath)") }
        if ($null -eq $result.PSObject.Properties['ExitCode']) { throw (New-PackageFailure 'Process hook result must contain ExitCode.') }
        return [pscustomobject]@{
            ExitCode = [int]$result.ExitCode
            StdOut = if ($null -eq $result.StdOut) { '' } else { [string]$result.StdOut }
            StdErr = if ($null -eq $result.StdErr) { '' } else { [string]$result.StdErr }
        }
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Spec.FilePath
    $start.WorkingDirectory = $Spec.WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $argumentList = $start.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentList) {
        foreach ($argument in @($Spec.Arguments)) { [void]$start.ArgumentList.Add([string]$argument) }
    } else {
        $start.Arguments = (@($Spec.Arguments) | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string]$_) }) -join ' '
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw (New-PackageFailure "Failed to start $($Spec.FilePath)") }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeout = if ($Spec.TimeoutSeconds) { [int]$Spec.TimeoutSeconds } else { 1800 }
        if (-not $process.WaitForExit($timeout * 1000)) {
            try { $process.Kill() } catch {}
            throw (New-PackageFailure "Process timed out after $timeout seconds: $($Spec.FilePath)")
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdoutTask.GetAwaiter().GetResult(); StdErr = $stderrTask.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

function Assert-ProcessSuccess {
    param($Result, [string]$Description)
    if ($Result.ExitCode -ne 0) {
        $detail = ([string]$Result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = ([string]$Result.StdOut).Trim() }
        if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
        throw (New-PackageFailure "$Description failed with exit code $($Result.ExitCode). $detail")
    }
}

function Get-PackageFallbackFiles {
    param([string]$RepoRoot, $Inputs)
    $relative = @(
        'windows/claude-switch.ps1',
        'windows/SwitcherUI.ps1',
        'windows/install.ps1',
        'windows/claude-bodyguard.ps1',
        'windows/README.md',
        'README.md',
        'LICENSE',
        'SECURITY.md'
    )
    $result = New-Object System.Collections.ArrayList
    foreach ($path in $relative) {
        [void]$result.Add([pscustomobject]@{ RelativePath = $path; SourcePath = (Assert-RequiredFile $RepoRoot $path "fallback payload") })
    }
    foreach ($file in $Inputs.HelperFiles) {
        $relativePath = 'windows/helpers/' + $file.FullName.Substring($Inputs.HelperDirectory.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        [void]$result.Add([pscustomobject]@{ RelativePath = $relativePath; SourcePath = $file.FullName })
    }
    return @($result | Sort-Object RelativePath)
}

function Assert-ClosedArchiveList {
    param([object[]]$Files)
    $allowed = @(
        'windows/claude-switch.ps1', 'windows/SwitcherUI.ps1', 'windows/install.ps1',
        'windows/claude-bodyguard.ps1', 'windows/README.md', 'README.md', 'LICENSE', 'SECURITY.md'
    )
    foreach ($file in $Files) {
        $path = ([string]$file.RelativePath).Replace('\', '/')
        if ($path -match '(^|/)(bin|obj|accounts|tests)(/|$)|(^|/)(last-check\.txt|lastip)(/|$)') {
            throw (New-PackageFailure "Fallback archive path is forbidden: $path")
        }
        if ($allowed -notcontains $path -and $path -notmatch '^windows/helpers/[A-Za-z0-9._/-]+$') {
            throw (New-PackageFailure "Fallback archive path is outside the closed allowlist: $path")
        }
        if ($path -match '(^|/)\.\.(/|$)|^/|^[A-Za-z]:') { throw (New-PackageFailure "Unsafe archive path: $path") }
    }
}

function New-PackageZip {
    param([string]$ZipPath, [string]$RepoRoot, [object[]]$Files)
    Assert-ClosedArchiveList $Files
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $timestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            foreach ($file in @($Files | Sort-Object RelativePath)) {
                $entry = $archive.CreateEntry(([string]$file.RelativePath).Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $input = [IO.File]::OpenRead($file.SourcePath)
                try {
                    $output = $entry.Open()
                    try { $input.CopyTo($output) } finally { $output.Dispose() }
                } finally { $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Copy-ClosedStageFile {
    param([string]$Source, [string]$StageRoot, [string]$RelativePath)
    $destination = Assert-PathWithin (Join-Path $StageRoot $RelativePath) $StageRoot 'stage destination'
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function Get-StagedPayloadPlan {
    param($Inputs, [string]$RepoRoot, [string]$PublishApp, [string]$PublishAdmin)
    $plan = New-Object System.Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $PublishApp -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($PublishApp.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -match '(^|/)(bin|obj|accounts|tests)(/|$)|(^|/)(last-check\.txt|lastip)(/|$)') { throw (New-PackageFailure "Published app contains forbidden payload: $relative") }
        [void]$plan.Add([pscustomobject]@{ RelativePath = $relative; SourcePath = $file.FullName })
    }
    if (-not @($plan | Where-Object { $_.RelativePath -eq 'ClaudeSwitcher.exe' })) { throw (New-PackageFailure 'Published app payload is missing ClaudeSwitcher.exe.') }
    foreach ($file in @(Get-ChildItem -LiteralPath $PublishAdmin -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($PublishAdmin.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -match '(^|/)(bin|obj|accounts|tests)(/|$)|(^|/)(last-check\.txt|lastip)(/|$)') { throw (New-PackageFailure "Published admin contains forbidden payload: $relative") }
        [void]$plan.Add([pscustomobject]@{ RelativePath = 'helpers/' + $relative; SourcePath = $file.FullName })
    }
    if (-not @($plan | Where-Object { $_.RelativePath -eq 'helpers/ClaudeSwitcher.Admin.exe' })) { throw (New-PackageFailure 'Published admin payload is missing ClaudeSwitcher.Admin.exe.') }
    foreach ($name in @('claude-switch.ps1', 'SwitcherUI.ps1', 'install.ps1', 'claude-bodyguard.ps1')) {
        [void]$plan.Add([pscustomobject]@{ RelativePath = 'scripts/' + $name; SourcePath = (Assert-RequiredFile $RepoRoot ('windows/' + $name) 'staged Windows script') })
    }
    foreach ($file in $Inputs.HelperFiles) {
        $relative = 'helpers/' + $file.FullName.Substring($Inputs.HelperDirectory.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('\', '/')
        [void]$plan.Add([pscustomobject]@{ RelativePath = $relative; SourcePath = $file.FullName })
    }
    [void]$plan.Add([pscustomobject]@{ RelativePath = 'LICENSE'; SourcePath = $Inputs.Files.License })
    return @($plan | Sort-Object RelativePath)
}

function Assert-NoPlaceholders {
    param([string]$RepoRoot)
    $inno = Join-Path $RepoRoot 'windows/ClaudeSwitcher.iss'
    $text = [IO.File]::ReadAllText($inno)
    if ($text -match '(?i)\b(TODO|TBD|PLACEHOLDER|FIXME)\b|\{\{[^}]+\}\}') { throw (New-PackageFailure 'Inno template contains an unresolved placeholder.') }
    if ($text -notmatch '(?im)^\s*AppId\s*=') { throw (New-PackageFailure 'Inno template must define AppId explicitly.') }
    foreach ($required in @('AppVersion', 'AppFileVersion', 'StageDir', 'OutputDir', 'OutputBaseFilename')) {
        if ($text -notmatch ('(?i)\b' + [regex]::Escape($required) + '\b')) {
            throw (New-PackageFailure "Inno template must consume the $required compile define.")
        }
    }
}


function Invoke-WindowsPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$DotnetPath,
        [string]$IsccPath,
        [string]$GitPath,
        [string]$PowerShell7Path,
        [scriptblock]$ProcessRunner
    )
    Assert-ProductionMode -ProcessRunner $ProcessRunner -LibraryMode $script:PackageLibraryMode
    $versionInfo = Get-SafeReleaseVersion $Version
    $repo = Get-CanonicalFullPath $RepoRoot (Get-Location).Path
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw (New-PackageFailure "Repository root does not exist: $RepoRoot") }
    $outputRoot = Get-CanonicalFullPath $OutputDirectory $repo
    if ($outputRoot -eq $repo -or $outputRoot -eq [IO.Path]::GetPathRoot($repo)) { throw (New-PackageFailure 'OutputDirectory must not be the repository root or a drive root.') }
    $buildRoot = Assert-PathWithin (Join-Path $repo 'build') $repo 'repository build root'
    $outputInsideRepo = $outputRoot.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or $outputRoot.StartsWith(($repo.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)
    if ($outputInsideRepo) { [void](Assert-PathWithin $outputRoot $buildRoot 'repository OutputDirectory') }
    $inputs = Get-RequiredPackageInputs $repo
    Assert-NoPlaceholders $repo
    $tools = Get-PackageTools $repo $DotnetPath $IsccPath $GitPath $PowerShell7Path
    Assert-DotnetPin $repo $tools.Dotnet $ProcessRunner

    $versionDirectory = Assert-PathWithin (Join-Path $outputRoot $versionInfo.Version) $outputRoot 'version output directory'
    $stagingRoot = Assert-PathWithin (Join-Path $versionDirectory '.staging') $versionDirectory 'staging directory'
    $publishRoot = Assert-PathWithin (Join-Path $versionDirectory '.publish') $versionDirectory 'publish directory'
    if (Test-Path -LiteralPath $versionDirectory) {
        $existing = @(Get-ChildItem -LiteralPath $versionDirectory -Force)
        if ($existing.Count -gt 0) { throw (New-PackageFailure "Version output directory is not empty: $versionDirectory") }
    } else { New-Item -ItemType Directory -Path $versionDirectory -Force | Out-Null }
    $stageRoot = Join-Path $stagingRoot 'payload'
    New-Item -ItemType Directory -Path $stageRoot, $publishRoot -Force | Out-Null

    $setupName = "ClaudeSwitcher-$Version-windows-setup.exe"
    $zipName = "ClaudeSwitcher-$Version-windows.zip"
    $manifestName = 'manifest.json'
    $setupPath = Join-Path $versionDirectory $setupName
    $zipPath = Join-Path $versionDirectory $zipName
    $manifestPath = Join-Path $versionDirectory $manifestName

    try {
        foreach ($coreHost in @($tools.SystemPowerShell, $tools.PowerShell7)) {
            if ([string]::IsNullOrWhiteSpace($coreHost)) { continue }
            $runnerPath = Join-Path $repo 'windows/tests/Invoke-CoreTests.ps1'
            $coreResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{
                FilePath = $coreHost
                Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath)
                WorkingDirectory = $repo
                TimeoutSeconds = 900
            })
            Assert-ProcessSuccess $coreResult "PowerShell core tests via $(Split-Path -Leaf $coreHost)"

            $setupRunnerPath = Join-Path $repo 'windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1'
            $setupResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{
                FilePath = $coreHost
                Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $setupRunnerPath)
                WorkingDirectory = $repo
                TimeoutSeconds = 300
            })
            Assert-ProcessSuccess $setupResult "isolated user setup tests via $(Split-Path -Leaf $coreHost)"

            $protocolRunnerPath = Join-Path $repo 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1'
            $protocolResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{
                FilePath = $coreHost
                Arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $protocolRunnerPath)
                WorkingDirectory = $repo
                TimeoutSeconds = 300
            })
            Assert-ProcessSuccess $protocolResult "isolated installer protocol tests via $(Split-Path -Leaf $coreHost)"
        }

        foreach ($testProject in @(
            (Join-Path $repo 'windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj'),
            (Join-Path $repo 'windows/ClaudeSwitcher.Admin.Tests/ClaudeSwitcher.Admin.Tests.csproj')
        )) {
            $testResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{
                FilePath = $tools.Dotnet
                Arguments = @('test', $testProject, '-c', 'Release')
                WorkingDirectory = $repo
                TimeoutSeconds = 1800
            })
            Assert-ProcessSuccess $testResult "dotnet test $testProject"
        }

        $publishApp = Join-Path $publishRoot 'app'
        $publishAdmin = Join-Path $publishRoot 'admin'
        foreach ($publish in @(
            @{ Project = 'windows/ClaudeSwitcher.App/ClaudeSwitcher.App.csproj'; Output = $publishApp },
            @{ Project = 'windows/ClaudeSwitcher.Admin/ClaudeSwitcher.Admin.csproj'; Output = $publishAdmin }
        )) {
            $publishResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{
                FilePath = $tools.Dotnet
                Arguments = @('publish', (Join-Path $repo $publish.Project), '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true', '-p:PublishSingleFile=false', '-p:PublishTrimmed=false', '-p:PublishAot=false', '-o', $publish.Output)
                WorkingDirectory = $repo
                TimeoutSeconds = 1800
            })
            Assert-ProcessSuccess $publishResult "dotnet publish $($publish.Project)"
        }

        $plan = Get-StagedPayloadPlan $inputs $repo $publishApp $publishAdmin
        foreach ($file in $plan) { Copy-ClosedStageFile $file.SourcePath $stageRoot $file.RelativePath }
        if (-not (Test-Path -LiteralPath (Join-Path $stageRoot 'ClaudeSwitcher.exe') -PathType Leaf)) { throw (New-PackageFailure 'Required published payload is missing: ClaudeSwitcher.exe') }

        $isccArgs = @(
            ('/DAppVersion=' + $versionInfo.Version),
            ('/DAppFileVersion=' + $versionInfo.InstallerVersion),
            ('/DStageDir=' + $stageRoot),
            ('/DOutputDir=' + $versionDirectory),
            ('/DOutputBaseFilename=' + [IO.Path]::GetFileNameWithoutExtension($setupName)),
            (Join-Path $repo 'windows/ClaudeSwitcher.iss')
        )
        $compileResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{ FilePath = $tools.Iscc; Arguments = $isccArgs; WorkingDirectory = $repo; TimeoutSeconds = 1800 })
        Assert-ProcessSuccess $compileResult 'Inno Setup compilation'
        $compilerPattern = '(?m)^Compiler engine version: Inno Setup ' + [regex]::Escape($script:InnoToolVersion) + '(?:\s|$)'
        if ([string]$compileResult.StdOut -notmatch $compilerPattern) {
            throw (New-PackageFailure "Inno Setup must report the reviewed compiler version $script:InnoToolVersion.")
        }
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw (New-PackageFailure "Inno Setup did not produce $setupName") }

        $fallbackFiles = Get-PackageFallbackFiles $repo $inputs
        New-PackageZip $zipPath $repo $fallbackFiles
        $gitResult = Invoke-PackageProcess -Runner $ProcessRunner -Spec ([pscustomobject]@{ FilePath = $tools.Git; Arguments = @('rev-parse', 'HEAD'); WorkingDirectory = $repo; TimeoutSeconds = 60 })
        Assert-ProcessSuccess $gitResult 'git rev-parse HEAD'
        $commit = ([string]$gitResult.StdOut).Trim()
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw (New-PackageFailure 'git rev-parse HEAD did not return a 40-character commit.') }

        $setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
        $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        $manifest = [ordered]@{
            schemaVersion = 1
            product = 'ClaudeSwitcher'
            version = $versionInfo.Version
            installerVersion = $versionInfo.InstallerVersion
            runtime = $script:PackageRuntime
            sourceCommit = $commit
            outputSubdirectory = $versionInfo.Version
            artifacts = [ordered]@{
                setup = [ordered]@{ name = $setupName; sha256 = $setupHash; size = (Get-Item -LiteralPath $setupPath).Length }
                zip = [ordered]@{ name = $zipName; sha256 = $zipHash; size = (Get-Item -LiteralPath $zipPath).Length }
            }
        }
        $manifestJson = $manifest | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($manifestPath, $manifestJson + "`r`n", (New-Object Text.UTF8Encoding($false)))

        Remove-Item -LiteralPath $stagingRoot, $publishRoot -Recurse -Force
        return [pscustomobject]@{
            Version = $versionInfo.Version
            InstallerVersion = $versionInfo.InstallerVersion
            OutputDirectory = $versionDirectory
            SetupPath = $setupPath
            ZipPath = $zipPath
            ManifestPath = $manifestPath
            Manifest = ($manifestJson | ConvertFrom-Json)
        }
    } catch {
        foreach ($artifactPath in @($setupPath, $zipPath, $manifestPath)) {
            if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                Remove-Item -LiteralPath $artifactPath -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($temporary in @($stagingRoot, $publishRoot)) {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $versionDirectory) {
            $remaining = @(Get-ChildItem -LiteralPath $versionDirectory -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $versionDirectory -Force -ErrorAction SilentlyContinue }
        }
        throw
    }
}

if (-not $script:PackageLibraryMode) {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw (New-PackageFailure 'OutputDirectory is required.') }
    $root = if ($RepoRoot) { $RepoRoot } else { Split-Path $PSScriptRoot -Parent }
    $arguments = @{
        Version = $Version
        OutputDirectory = $OutputDirectory
        RepoRoot = $root
    }
    if (-not [string]::IsNullOrWhiteSpace($DotnetPath)) { $arguments.DotnetPath = $DotnetPath }
    if (-not [string]::IsNullOrWhiteSpace($IsccPath)) { $arguments.IsccPath = $IsccPath }
    if (-not [string]::IsNullOrWhiteSpace($GitPath)) { $arguments.GitPath = $GitPath }
    if (-not [string]::IsNullOrWhiteSpace($PowerShell7Path)) { $arguments.PowerShell7Path = $PowerShell7Path }
    if ($null -ne $ProcessRunner) { $arguments.ProcessRunner = $ProcessRunner }
    $result = Invoke-WindowsPackage @arguments
    $result | ConvertTo-Json -Depth 5
    exit 0
}
