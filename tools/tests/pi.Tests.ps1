# Pi's npm-proxy/GitHub release comparison and source-aware action planning.
$scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tool-checker.ps1'
$selectionFile = Join-Path ([System.IO.Path]::GetTempPath()) 'tool-checker-pi-tests.env'
Set-Content -LiteralPath $selectionFile -Value 'TOOL_CHECKER_TOOLS=pi'
. $scriptPath -EnvFile $selectionFile

Describe 'Pi upstream release selection' {
    BeforeEach {
        $results = New-ToolCheckResults
        $SkipUpdate = $false
        Mock Test-CommandExists { $true }
        Mock Get-CommandVersion { '0.87.1' }
        $script:MockPiRegistryVersion = '0.87.1'
        $script:MockPiGitHubTag = 'v0.99.1'
        Mock Invoke-RestMethod {
            $version = $script:MockPiRegistryVersion
            [pscustomobject]@{
                'dist-tags' = [pscustomobject]@{ latest = $version }
                versions = [pscustomobject]@{ $version = @{} }
            }
        } -ParameterFilter { $Uri -notmatch 'api.github.com' }
        Mock Invoke-RestMethod {
            @([pscustomobject]@{ name = $script:MockPiGitHubTag; commit = [pscustomobject]@{ sha = 'abc' } })
        } -ParameterFilter { $Uri -match 'api.github.com' }
    }

    It 'prefers a newer GitHub tag over a stale npm-proxy version and pins the source action' {
        Invoke-ToolEntryPoint -ToolId 'pi' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '' }

        $results.Tools.Pi.Installed | Should Be '0.87.1'
        $results.Tools.Pi.Latest | Should Be '0.99.1'
        $results.Tools.Pi.LatestReleased | Should Be '0.99.1'
        $results.AvailableUpdates.Count | Should Be 1
        $results.AvailableUpdates[0].Version | Should Be '0.99.1'
        $results.AvailableUpdates[0].Executor | Should Be 'tool'
        $results.AvailableUpdates[0].Arguments.Source | Should Be 'github'
        $results.AvailableUpdates[0].Arguments.Tag | Should Be 'v0.99.1'
    }

    It 'uses npm when its version is equal to or newer than the GitHub tag' {
        $script:MockPiRegistryVersion = '1.2.0'
        $script:MockPiGitHubTag = 'v1.1.0'

        Invoke-ToolEntryPoint -ToolId 'pi' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '' }

        $results.Tools.Pi.Latest | Should Be '1.2.0'
        $results.AvailableUpdates[0].Arguments.Source | Should Be 'npm'
        $results.AvailableUpdates[0].Arguments.Version | Should Be '1.2.0'
    }

    It 'does not query releases in check-only mode' {
        $SkipUpdate = $true
        Mock Invoke-RestMethod { throw 'Release lookup should not run' }

        Invoke-ToolEntryPoint -ToolId 'pi' -EntryPoint 'Test-Tool' -Arguments @{ Progress = '' }

        $results.Tools.Pi.Installed | Should Be '0.87.1'
        $results.Tools.Pi.Latest | Should Be ''
        $results.AvailableUpdates.Count | Should Be 0
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }
}
