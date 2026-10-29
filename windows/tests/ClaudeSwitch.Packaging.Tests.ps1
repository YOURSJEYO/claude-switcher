# Dot-sourced by the isolated PowerShell runner when controller wires Task 6.
# Every packaging test uses synthetic repositories and fake process hooks. No build,
# installer, account, Claude, network, or system-setting operation is performed.

$script:PackagingScript = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/package-windows.ps1'
$script:PackagingLoadError = $null
if (Test-Path -LiteralPath $script:PackagingScript -PathType Leaf) {
    try { . $script:PackagingScript } catch { $script:PackagingLoadError = $_.Exception.Message }
} else {
    $script:PackagingLoadError = 'Packaging script missing: ' + $script:PackagingScript
}

function Assert-PackageContains {
    param([object[]]$Items, $Expected, [string]$Message)
    if (@($Items) -notcontains $Expected) { throw "ASSERT: $Message (missing=$Expected)" }
}

function Assert-PackageThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $threw = $false
    $actual = ''
    try { & $Action } catch {
        $threw = $true
        $actual = $_.Exception.Message
    }
    if (-not $threw) { throw "ASSERT: $Message (no exception)" }
    if ($actual -notmatch $Pattern) { throw "ASSERT: $Message (pattern=$Pattern actual=$actual)" }
}

function New-PackageFixtureFile {
    param([string]$Root, [string]$RelativePath, [string]$Content = 'fixture')
    $path = Join-Path $Root $RelativePath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $path }
}

function New-PackageFixture {
    $root = Join-Path $script:TestRoot ('packaging-' + [guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    New-PackageFixtureFile $root 'global.json' '{"sdk":{"version":"10.0.403","rollForward":"disable"}}' | Out-Null
    foreach ($scriptName in @('claude-switch.ps1', 'SwitcherUI.ps1', 'install.ps1', 'claude-bodyguard.ps1')) {
        New-PackageFixtureFile $root (Join-Path 'windows' $scriptName) "# synthetic $scriptName" | Out-Null
    }
    New-PackageFixtureFile $root 'windows/helpers/bodyguard-template.ps1' '# synthetic helper' | Out-Null
    New-PackageFixtureFile $root 'windows/helpers/setup.json' '{"synthetic":true}' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.App/ClaudeSwitcher.App.csproj' '<Project />' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj' '<Project />' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.Admin/ClaudeSwitcher.Admin.csproj' '<Project />' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.Admin.Tests/ClaudeSwitcher.Admin.Tests.csproj' '<Project />' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1' '# synthetic isolated setup tests' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1' '# synthetic isolated installer protocol tests' | Out-Null
    $innoLines = @(
        'AppId={{C9C4AFA1-7F4A-47CC-B6DB-4B6DA0A90961}',
        'AppVersion={#AppVersion}',
        'AppFileVersion={#AppFileVersion}',
        'StageDir={#StageDir}',
        'OutputDir={#OutputDir}',
        'OutputBaseFilename={#OutputBaseFilename}'
    )
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.iss' ($innoLines -join "`n") | Out-Null
    New-PackageFixtureFile $root 'windows/tests/Invoke-CoreTests.ps1' '# synthetic core runner' | Out-Null
    New-PackageFixtureFile $root 'windows/README.md' '# synthetic Windows readme' | Out-Null
    New-PackageFixtureFile $root 'README.md' '# synthetic readme' | Out-Null
    New-PackageFixtureFile $root 'LICENSE' 'synthetic license' | Out-Null
    New-PackageFixtureFile $root 'SECURITY.md' '# synthetic security' | Out-Null

    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.App/bin/private.dll' 'private bin payload' | Out-Null
    New-PackageFixtureFile $root 'windows/ClaudeSwitcher.App/obj/private.cs' 'private obj payload' | Out-Null
    New-PackageFixtureFile $root 'windows/tests/private-test.ps1' '# private test payload' | Out-Null
    New-PackageFixtureFile $root 'windows/accounts/A/identity.txt' 'private account payload' | Out-Null
    New-PackageFixtureFile $root 'windows/last-check.txt' 'private check state' | Out-Null
    New-PackageFixtureFile $root 'windows/lastip' '203.0.113.7' | Out-Null

    $toolRoot = Join-Path $root 'isolated-tools'
    $innoRoot = Join-Path $toolRoot 'Inno Setup 6'
    New-Item -ItemType Directory -Path $innoRoot -Force | Out-Null
    $dotnet = (New-PackageFixtureFile $root 'isolated-tools/dotnet.exe' 'fake tool').Path
    $iscc = (New-PackageFixtureFile $root 'isolated-tools/Inno Setup 6/ISCC.exe' 'fake tool').Path
    $git = (New-PackageFixtureFile $root 'isolated-tools/git.exe' 'fake tool').Path
    $pwsh = (New-PackageFixtureFile $root 'isolated-tools/pwsh.exe' 'fake tool').Path

    return [pscustomobject]@{
        Root = $root
        Output = (Join-Path $root 'build/artifacts')
        Dotnet = $dotnet
        Iscc = $iscc
        Git = $git
        Pwsh = $pwsh
    }
}

function New-PackageProcessFixture {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [string]$Pin = '10.0.403',
        [string]$InnoVersion = '6.7.3',
        [bool]$OmitAppExecutable = $false,
        [int]$ProtocolExitCode = 0
    )
    $state = [pscustomobject]@{
        Calls = New-Object System.Collections.ArrayList
        Pin = $Pin
        InnoVersion = $InnoVersion
        Commit = ('a' * 40)
        OmitAppExecutable = $OmitAppExecutable
        ProtocolExitCode = $ProtocolExitCode
        StageFiles = @()
        StageVersion = $null
    }
    $runner = {
        param($Spec)
        [void]$state.Calls.Add($Spec)
        $leaf = [IO.Path]::GetFileName($Spec.FilePath)
        $args = @($Spec.Arguments)

        if ($leaf -ieq 'dotnet.exe') {
            if ($args.Count -eq 1 -and $args[0] -eq '--version') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $state.Pin; StdErr = '' }
            }
            if ($args.Count -ge 2 -and $args[0] -eq 'test') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'synthetic tests passed'; StdErr = '' }
            }
            if ($args.Count -ge 2 -and $args[0] -eq 'publish') {
                $output = ''
                for ($i = 0; $i -lt $args.Count - 1; $i++) {
                    if ($args[$i] -eq '-o') { $output = $args[$i + 1]; break }
                }
                if (-not $output) { throw 'fake dotnet publish received no -o argument' }
                New-Item -ItemType Directory -Path $output -Force | Out-Null
                $isAdmin = $args[1] -match 'ClaudeSwitcher\.Admin'
                if ($isAdmin) {
                    [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.Admin.exe'), 'fake admin executable')
                    [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.Admin.dll'), 'fake admin assembly')
                    [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.Admin.runtimeconfig.json'), '{}')
                } else {
                    if (-not $state.OmitAppExecutable) {
                        [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.exe'), 'fake app executable')
                    }
                    [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.dll'), 'fake app assembly')
                    [IO.File]::WriteAllText((Join-Path $output 'ClaudeSwitcher.runtimeconfig.json'), '{}')
                    $runtimeDir = Join-Path $output 'runtimes/win-x64/native'
                    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path $runtimeDir 'fixture.dll'), 'fake native payload')
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'synthetic publish passed'; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "unexpected fake dotnet command: $($args -join ' ')" }
        }

        if ($leaf -ieq 'powershell.exe' -or $leaf -ieq 'pwsh.exe') {
            $protocolPath = Join-Path $Fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1'
            if ($args -contains $protocolPath) {
                return [pscustomobject]@{ ExitCode = $state.ProtocolExitCode; StdOut = 'synthetic installer protocol tests passed'; StdErr = 'synthetic installer protocol failure' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = 'synthetic isolated tests passed'; StdErr = '' }
        }

        if ($leaf -ieq 'git.exe') {
            if (($args -join ' ') -eq 'rev-parse HEAD') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $state.Commit; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "unexpected fake git command: $($args -join ' ')" }
        }

        if ($leaf -ieq 'ISCC.exe') {
            $defines = @{}
            foreach ($arg in $args) {
                if ($arg -match '^/D([^=]+)=(.*)$') { $defines[$Matches[1]] = $Matches[2] }
            }
            if (-not $defines.ContainsKey('StageDir') -or -not $defines.ContainsKey('OutputDir') -or -not $defines.ContainsKey('OutputBaseFilename')) {
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fake ISCC missing required compile defines' }
            }
            $stage = $defines['StageDir']
            $state.StageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object {
                $_.FullName.Substring($stage.Length).TrimStart('\', '/').Replace('\', '/')
            } | Sort-Object)
            $stageVersionPath = Join-Path $stage 'VERSION'
            if (Test-Path -LiteralPath $stageVersionPath -PathType Leaf) {
                $state.StageVersion = [IO.File]::ReadAllText($stageVersionPath)
            }
            $output = $defines['OutputDir']
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $output ($defines['OutputBaseFilename'] + '.exe')), 'fake compiled setup')
            return [pscustomobject]@{ ExitCode = 0; StdOut = ('Compiler engine version: Inno Setup ' + $state.InnoVersion + "`r`nsynthetic compile passed"); StdErr = '' }
        }

        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "unexpected fake tool: $($Spec.FilePath)" }
    }.GetNewClosure()

    return [pscustomobject]@{ Runner = $runner; State = $state }
}

function Invoke-PackageFixture {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][scriptblock]$Runner,
        [string]$Version = '1.2.3-beta.1',
        [string]$DotnetPath,
        [string]$IsccPath,
        [string]$GitPath,
        [string]$PowerShell7Path,
        [string]$OutputDirectory
    )
    if (-not $DotnetPath) { $DotnetPath = $Fixture.Dotnet }
    if (-not $OutputDirectory) { $OutputDirectory = $Fixture.Output }
    if (-not $IsccPath) { $IsccPath = $Fixture.Iscc }
    if (-not $GitPath) { $GitPath = $Fixture.Git }
    if (-not $PowerShell7Path) { $PowerShell7Path = $Fixture.Pwsh }
    if ($script:PackagingLoadError) { throw $script:PackagingLoadError }
    return Invoke-WindowsPackage -Version $Version -OutputDirectory $OutputDirectory -RepoRoot $Fixture.Root `
        -DotnetPath $DotnetPath -IsccPath $IsccPath -GitPath $GitPath -PowerShell7Path $PowerShell7Path `
        -ProcessRunner $Runner
}

function Get-PackageZipEntryNames {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { return @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object) }
    finally { $zip.Dispose() }
}

function Get-PackageZipEntryText {
    param([string]$Path, [string]$Name)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry($Name)
        if ($null -eq $entry) { throw "ASSERT: ZIP entry is missing: $Name" }
        $reader = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

Add-CoreTest -Tag Packaging -Name 'production mode rejects the fake process hook before tool discovery' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows {
        Assert-ProductionMode -ProcessRunner $process.Runner -LibraryMode:$false
    } 'process hook|ProcessRunner' 'production must never accept a test process hook'
    Assert-Equal 0 $process.State.Calls.Count 'rejected hook must not be invoked'
}

Add-CoreTest -Tag Packaging -Name 'Windows argument quoting preserves spaces quotes and trailing slashes' {
    $cases = @(
        @{ Value = 'plain'; Expected = 'plain' },
        @{ Value = 'two words'; Expected = '"two words"' },
        @{ Value = 'say "hello"'; Expected = '"say \"hello\""' },
        @{ Value = 'C:\path with space\'; Expected = '"C:\path with space\\"' },
        @{ Value = ''; Expected = '""' }
    )
    foreach ($case in $cases) {
        Assert-Equal $case.Expected (ConvertTo-WindowsCommandLineArgument $case.Value) "argument quoting: [$($case.Value)]"
    }
}

Add-CoreTest -Tag Packaging -Name 'repository output is confined to the build tree unless isolated' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $insideRepo = Join-Path $fixture.Root 'user-data-output'
    Assert-PackageThrows {
        Invoke-WindowsPackage -Version '1.2.3' -OutputDirectory $insideRepo -RepoRoot $fixture.Root `
            -DotnetPath $fixture.Dotnet -IsccPath $fixture.Iscc -GitPath $fixture.Git -PowerShell7Path $fixture.Pwsh `
            -ProcessRunner $process.Runner
    } 'build|repository|OutputDirectory|isolated' 'repository output outside build must be rejected'
    Assert-Equal 0 $process.State.Calls.Count 'output containment is checked before tools'
    Assert-False (Test-Path -LiteralPath $insideRepo) 'unsafe output must not be created'

    $isolatedOutput = Join-Path $script:TestRoot ('isolated-output-' + [guid]::NewGuid().Guid)
    $isolated = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner -OutputDirectory $isolatedOutput
    Assert-Equal (Join-Path $isolatedOutput '1.2.3-beta.1') $isolated.OutputDirectory 'explicit output outside the repository remains available for isolated builds'
    Assert-True (Test-Path -LiteralPath $isolated.SetupPath -PathType Leaf) 'isolated output receives the setup'
}
Add-CoreTest -Tag Packaging -Name 'unsafe versions are rejected before any tool call' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    foreach ($version in @('', 'v1.2.3', '1.2', '1.2.3.4', '01.2.3', '1.2.3-', '1.2.3-beta_1', '1.2.3+meta', '../1.2.3', '1.2.3/evil')) {
        Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner -Version $version } 'version|版本|Version' "unsafe version must be rejected: [$version]"
    }
    Assert-Equal 0 $process.State.Calls.Count 'validation must occur before invoking tools'
    Assert-False (Test-Path -LiteralPath $fixture.Output) 'invalid versions must not create output'
}

Add-CoreTest -Tag Packaging -Name 'valid numeric and simple suffix versions map to safe setup versions' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner -Version '1.2.3-beta.1'
    Assert-Equal '1.2.3-beta.1' $result.Version 'release version is preserved'
    Assert-Equal '1.2.3.1' $result.InstallerVersion 'suffix maps to a safe numeric file version'
    Assert-Match '^1\.2\.3\.1$' $result.Manifest.installerVersion 'manifest records installer file version'
    Assert-True ($process.State.Calls.Count -gt 0) 'valid package performs work'
}

Add-CoreTest -Tag Packaging -Name 'missing dotnet pin fails before build' {
    $fixture = New-PackageFixture
    [IO.File]::WriteAllText((Join-Path $fixture.Root 'global.json'), '{"sdk":{"version":"10.0.999","rollForward":"disable"}}')
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'SDK|sdk|pin|global\.json' 'SDK mismatch must fail'
    Assert-False (@($process.State.Calls | Where-Object { $_.Arguments -contains 'test' -or $_.Arguments -contains 'publish' }).Count -gt 0) 'no build runs after pin mismatch'
}

Add-CoreTest -Tag Packaging -Name 'unexpected Inno compiler version cannot produce a release manifest' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture -InnoVersion '6.7.30'
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'Inno|compiler|6\.7\.3' 'unreviewed compiler version must fail closed'
    Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Output '1.2.3-beta.1/ClaudeSwitcher-1.2.3-beta.1-windows-setup.exe')) 'wrong compiler cannot leave a setup executable behind'
    Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Output '1.2.3-beta.1/manifest.json')) 'wrong compiler cannot emit completed manifest'
    Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Output '1.2.3-beta.1/ClaudeSwitcher-1.2.3-beta.1-windows.zip')) 'wrong compiler cannot emit the fallback release asset'
}

Add-CoreTest -Tag Packaging -Name 'missing required tool fails explicitly' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner -IsccPath (Join-Path $fixture.Root 'missing-ISCC.exe') } 'ISCC|Inno' 'missing ISCC must fail'
    Assert-False (@($process.State.Calls | Where-Object { $_.Arguments -contains 'test' }).Count -gt 0) 'tool discovery precedes tests'
}

Add-CoreTest -Tag Packaging -Name 'tool discovery falls back to a later command candidate' {
    $fixture = New-PackageFixture
    function Get-Command {
        param([string]$Name, [string]$ErrorAction)
        if ($Name -eq 'dotnet.exe') { return [pscustomobject]@{ CommandType='Application'; Source='C:\synthetic\dotnet.exe' } }
        return $null
    }
    $resolved = Resolve-PackageTool '' $fixture.Root @('build/tools/dotnet/dotnet.exe', 'dotnet.exe') '.NET SDK'
    Assert-Equal 'C:\synthetic\dotnet.exe' $resolved 'tool discovery must try later command candidates after missing repo-local tools'
}

Add-CoreTest -Tag Packaging -Name 'missing admin project fails clearly' {
    $fixture = New-PackageFixture
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin') -Recurse -Force
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'Admin|admin' 'missing admin project must fail'
    Assert-Equal 0 $process.State.Calls.Count 'missing source is checked before tools'
}

Add-CoreTest -Tag Packaging -Name 'missing Inno template fails clearly' {
    $fixture = New-PackageFixture
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'windows/ClaudeSwitcher.iss') -Force
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'Inno|\.iss|template' 'missing Inno template must fail'
    Assert-Equal 0 $process.State.Calls.Count 'missing template is checked before tools'
}

Add-CoreTest -Tag Packaging -Name 'missing required payload fails and leaves no completed outputs' {
    $fixture = New-PackageFixture
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'windows/helpers') -Recurse -Force
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'payload|setup\.json|required' 'missing helper payload must fail'
    Assert-False (Test-Path -LiteralPath (Join-Path $fixture.Output '1.2.3-beta.1')) 'failed package must not leave a completed version directory'
}

Add-CoreTest -Tag Packaging -Name 'missing published app executable fails before compile' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture -OmitAppExecutable $true
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'ClaudeSwitcher\.exe|published|payload' 'published app payload must be validated'
    Assert-False (@($process.State.Calls | Where-Object { [IO.Path]::GetFileName($_.FilePath) -ieq 'ISCC.exe' }).Count -gt 0) 'ISCC is not called when publish payload is incomplete'
}

Add-CoreTest -Tag Packaging -Name 'build commands use fixed arguments and core tests run on both PowerShell hosts' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner
    $dotnetCalls = @($process.State.Calls | Where-Object { [IO.Path]::GetFileName($_.FilePath) -ieq 'dotnet.exe' })
    $testCalls = @($dotnetCalls | Where-Object { $_.Arguments.Count -ge 2 -and $_.Arguments[0] -eq 'test' })
    $publishCalls = @($dotnetCalls | Where-Object { $_.Arguments.Count -ge 2 -and $_.Arguments[0] -eq 'publish' })
    Assert-Equal 2 $testCalls.Count 'app and admin test projects are tested'
    Assert-Equal 2 $publishCalls.Count 'app and admin projects are published'
    foreach ($call in $publishCalls) {
        Assert-True ($call.Arguments -contains 'win-x64') 'publish targets win-x64'
        Assert-True ($call.Arguments -contains '--self-contained') 'publish is self-contained'
        Assert-True ($call.Arguments -contains 'true') 'self-contained value is true'
        Assert-True ($call.Arguments -contains '-p:PublishSingleFile=false') 'single-file publishing is disabled'
    }
    $shellCalls = @($process.State.Calls | Where-Object { [IO.Path]::GetFileName($_.FilePath) -match '^(powershell|pwsh)\.exe$' })
    $coreCalls = @($shellCalls | Where-Object { $_.Arguments -contains (Join-Path $fixture.Root 'windows/tests/Invoke-CoreTests.ps1') })
    $setupCalls = @($shellCalls | Where-Object { $_.Arguments -contains (Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1') })
    Assert-Equal 2 $coreCalls.Count 'system PowerShell and available pwsh both run core tests'
    Assert-Equal 2 $setupCalls.Count 'isolated original-user setup tests run under both hosts before packaging'
    Assert-Equal 2 @($shellCalls | Where-Object { $_.Arguments -contains (Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1') }).Count 'isolated installer protocol tests run under both hosts before packaging'
    Assert-Match 'powershell\.exe$' $coreCalls[0].FilePath 'system Windows PowerShell is first'
    Assert-Match 'pwsh\.exe$' $coreCalls[1].FilePath 'PowerShell 7 is second'
    foreach ($call in $coreCalls) {
        Assert-True ($call.Arguments -contains '-File') 'core runner is invoked as a file'
        Assert-True ($call.Arguments -contains (Join-Path $fixture.Root 'windows/tests/Invoke-CoreTests.ps1')) 'fixed core runner path is used'
        Assert-False ($call.Arguments -contains '-Tag') 'packaging must run transaction, protocol and UI regressions, not only Core'
    }
    foreach ($call in $testCalls) {
        Assert-False ($call.Arguments -contains '--no-restore') 'a fresh checkout must restore test dependencies'
    }
    Assert-Equal 'win-x64' $result.Manifest.runtime 'manifest records win-x64 runtime'
}

Add-CoreTest -Tag Packaging -Name 'missing installer protocol tests fail before any process call' {
    $fixture = New-PackageFixture
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1') -Force
    $process = New-PackageProcessFixture -Fixture $fixture
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'InstallerProtocolTests|installer protocol|required' 'missing installer protocol tests must fail closed'
    Assert-Equal 0 $process.State.Calls.Count 'protocol preflight must run before tool discovery or process execution'
}

Add-CoreTest -Tag Packaging -Name 'installer protocol tests run after setup tests under each host before dotnet' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    [void](Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner)
    $protocolPath = Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1'
    $corePath = Join-Path $fixture.Root 'windows/tests/Invoke-CoreTests.ps1'
    $setupPath = Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/UserSetupTests.ps1'
    $protocolCalls = @($process.State.Calls | Where-Object { $_.Arguments -contains $protocolPath })
    Assert-Equal 2 $protocolCalls.Count 'protocol tests run once under Windows PowerShell and once under PowerShell 7'
    Assert-True ([IO.Path]::IsPathRooted($protocolPath)) 'protocol runner path is absolute'
    Assert-Match 'powershell\.exe$' $protocolCalls[0].FilePath 'Windows PowerShell runs first'
    Assert-Match 'pwsh\.exe$' $protocolCalls[1].FilePath 'PowerShell 7 runs second'
    foreach ($call in $protocolCalls) {
        $expectedArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $protocolPath)
        Assert-Equal ($expectedArguments -join "`n") ($call.Arguments -join "`n") 'protocol runner uses fixed isolated-process arguments'
        Assert-False ($call.Arguments -contains '-Tag') 'protocol runner must not filter its tests'
        Assert-Equal $fixture.Root $call.WorkingDirectory 'protocol runner uses the repository root'
        Assert-Equal 300 $call.TimeoutSeconds 'protocol runner has a bounded timeout'
        $hostCalls = @($process.State.Calls | Where-Object { $_.FilePath -eq $call.FilePath })
        Assert-Equal $corePath $hostCalls[0].Arguments[-1] 'core tests run first for this host'
        Assert-Equal $setupPath $hostCalls[1].Arguments[-1] 'user setup tests run second for this host'
        Assert-Equal $protocolPath $hostCalls[2].Arguments[-1] 'protocol tests run third for this host'
    }
    $firstDotnetIndex = -1
    $lastProtocolIndex = -1
    for ($i = 0; $i -lt $process.State.Calls.Count; $i++) {
        $call = $process.State.Calls[$i]
        if ($firstDotnetIndex -lt 0 -and [IO.Path]::GetFileName($call.FilePath) -ieq 'dotnet.exe' -and $call.Arguments.Count -gt 0 -and $call.Arguments[0] -in @('test', 'publish')) { $firstDotnetIndex = $i }
        if ($call.Arguments -contains $protocolPath) { $lastProtocolIndex = $i }
    }
    Assert-True ($firstDotnetIndex -ge 0 -and $lastProtocolIndex -lt $firstDotnetIndex) 'all protocol tests complete before dotnet test or publish'
}

Add-CoreTest -Tag Packaging -Name 'protocol test failure stops before dotnet test and publish' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture -ProtocolExitCode 23
    Assert-PackageThrows { Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner } 'installer protocol.*exit code 23' 'protocol failure must fail packaging'
    Assert-Equal 0 @($process.State.Calls | Where-Object { [IO.Path]::GetFileName($_.FilePath) -ieq 'dotnet.exe' -and $_.Arguments[0] -in @('test', 'publish') }).Count 'failed protocol tests must prevent builds'
}

Add-CoreTest -Tag Packaging -Name 'protocol tests run once when PowerShell 7 is unavailable' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $savedPath = $env:PATH
    $emptyPath = Join-Path $script:TestRoot ('empty-path-' + [guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
    try {
        $env:PATH = $emptyPath
        [void](Invoke-WindowsPackage -Version '1.2.3-beta.1' -OutputDirectory $fixture.Output -RepoRoot $fixture.Root `
            -DotnetPath $fixture.Dotnet -IsccPath $fixture.Iscc -GitPath $fixture.Git -ProcessRunner $process.Runner)
    } finally {
        $env:PATH = $savedPath
    }
    $protocolPath = Join-Path $fixture.Root 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1'
    $protocolCalls = @($process.State.Calls | Where-Object { $_.Arguments -contains $protocolPath })
    Assert-Equal 1 $protocolCalls.Count 'protocol tests run once without PowerShell 7'
    Assert-Match 'powershell\.exe$' $protocolCalls[0].FilePath 'the system host remains required'
}
Add-CoreTest -Tag Packaging -Name 'output paths are version-scoped and never delete arbitrary trees' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $sentinel = Join-Path $fixture.Output 'keep-me.txt'
    New-Item -ItemType Directory -Path $fixture.Output -Force | Out-Null
    [IO.File]::WriteAllText($sentinel, 'preserve')
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner
    Assert-Equal (Join-Path $fixture.Output '1.2.3-beta.1') $result.OutputDirectory 'output is one dedicated version directory'
    Assert-Equal 'preserve' ([IO.File]::ReadAllText($sentinel)) 'sibling output is untouched'
    Assert-Equal '1.2.3-beta.1' $result.Manifest.outputSubdirectory 'manifest records the dedicated version subdirectory'
}

Add-CoreTest -Tag Packaging -Name 'closed fallback zip contains approved scripts and helper files only' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner
    $names = Get-PackageZipEntryNames -Path $result.ZipPath
    foreach ($expected in @(
        'windows/claude-switch.ps1', 'windows/SwitcherUI.ps1', 'windows/install.ps1',
        'windows/claude-bodyguard.ps1', 'windows/helpers/bodyguard-template.ps1',
        'windows/helpers/setup.json', 'windows/README.md', 'README.md', 'LICENSE', 'SECURITY.md', 'VERSION'
    )) { Assert-PackageContains $names $expected "fallback zip must include $expected" }
    Assert-Equal 11 $names.Count 'fallback zip has an exact closed file list'
    Assert-Equal '1.2.3-beta.1' ((Get-PackageZipEntryText -Path $result.ZipPath -Name 'VERSION').Trim()) 'root VERSION records the package version'
    Assert-False ($names -contains 'windows/ClaudeSwitcher.Admin.Tests/InstallerProtocolTests.ps1') 'protocol tests are not release payload'
    foreach ($name in $names) {
        Assert-False ($name -match '(^|/)(bin|obj|accounts|tests)(/|$)') "archive must not contain private tree: $name"
        Assert-False ($name -match '(^|/)(last-check\.txt|lastip)(/|$)') "archive must not contain user state: $name"
    }
}

Add-CoreTest -Tag Packaging -Name 'setup and zip names agree with the manifest and checksums' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner
    Assert-Equal 'ClaudeSwitcher-1.2.3-beta.1-windows-setup.exe' (Split-Path -Leaf $result.SetupPath) 'setup filename is versioned'
    Assert-Equal 'ClaudeSwitcher-1.2.3-beta.1-windows.zip' (Split-Path -Leaf $result.ZipPath) 'zip filename is versioned'
    Assert-True (Test-Path -LiteralPath $result.ManifestPath -PathType Leaf) 'manifest exists'
    $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json
    Assert-Equal '1.2.3-beta.1' $manifest.version 'manifest version agrees'
    Assert-Equal '1.2.3.1' $manifest.installerVersion 'manifest installer version agrees'
    Assert-Equal 'win-x64' $manifest.runtime 'manifest runtime agrees'
    Assert-Equal $process.State.Commit $manifest.sourceCommit 'manifest binds source commit'
    Assert-Equal (Split-Path -Leaf $result.SetupPath) $manifest.artifacts.setup.name 'setup manifest name agrees'
    Assert-Equal (Split-Path -Leaf $result.ZipPath) $manifest.artifacts.zip.name 'zip manifest name agrees'
    Assert-Equal (Get-FileHash -LiteralPath $result.SetupPath -Algorithm SHA256).Hash $manifest.artifacts.setup.sha256 'setup SHA256 agrees'
    Assert-Equal (Get-FileHash -LiteralPath $result.ZipPath -Algorithm SHA256).Hash $manifest.artifacts.zip.sha256 'zip SHA256 agrees'
    Assert-Equal 2 @($manifest.artifacts.PSObject.Properties).Count 'manifest artifact list is closed to setup and zip'
}

Add-CoreTest -Tag Packaging -Name 'ISCC is used only for compilation and never executes generated setup' {
    $fixture = New-PackageFixture
    $process = New-PackageProcessFixture -Fixture $fixture
    $result = Invoke-PackageFixture -Fixture $fixture -Runner $process.Runner
    $isccCalls = @($process.State.Calls | Where-Object { [IO.Path]::GetFileName($_.FilePath) -ieq 'ISCC.exe' })
    Assert-Equal 1 $isccCalls.Count 'ISCC compiles exactly once'
    foreach ($call in $isccCalls) {
        Assert-False ($call.Arguments -contains '/Q') 'ISCC is invoked for compile, not silent installer execution'
        Assert-False (@($call.Arguments | Where-Object { $_ -match 'ClaudeSwitcher-.*-windows-setup\.exe$' }).Count -gt 0) 'ISCC never receives generated setup as an input'
    }
    Assert-True ($process.State.StageFiles -contains 'ClaudeSwitcher.exe') 'staged app executable is compiled into setup'
    Assert-True ($process.State.StageFiles -contains 'scripts/claude-switch.ps1') 'staged core script is compiled into setup'
    Assert-True ($process.State.StageFiles -contains 'helpers/ClaudeSwitcher.Admin.exe') 'admin helper is installed in the protected helper directory'
    Assert-False ($process.State.StageFiles -contains 'ClaudeSwitcher.Admin/ClaudeSwitcher.Admin.exe') 'runtime files are not placed outside the fixed helper directory'
    Assert-True ($process.State.StageFiles -contains 'helpers/setup.json') 'staged helper payload is compiled into setup'
    Assert-True ($process.State.StageFiles -contains 'VERSION') 'root VERSION is staged for installer scripts/../VERSION'
    Assert-Equal '1.2.3-beta.1' ($process.State.StageVersion.Trim()) 'staged root VERSION matches the package version'
    Assert-True ($process.State.StageFiles -contains 'LICENSE') 'project license is staged'
    Assert-False (@($process.State.StageFiles | Where-Object { $_ -match '(^|/)(bin|obj|accounts|tests)(/|$)|(^|/)(last-check\.txt|lastip)$' }).Count -gt 0) 'staging excludes private or generated trees'
}
