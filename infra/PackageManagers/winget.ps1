# Selected Windows package manager: compare package versions, run single WinGet
# commands, and classify no-applicable-package results without claiming success.
function Invoke-Command-PackageManager {
    param([string]$Command, [string]$Type)
    Invoke-WingetCommand -Command $Command -Type $Type
}

function Get-ExecutionOutcome-PackageManager {
    param([object]$Action, [int]$ExitCode, [string]$OutputText)
    if (Test-WingetNoUpdateResult -Action $Action -ExitCode $ExitCode -OutputText $OutputText) {
        @{ Status = 'Skipped'; Message = "Skipped: $($Action.Name) - winget has no newer package yet | Command: $($Action.Command) | Exit code: $ExitCode"; NoApplicablePackage = $true }
    }
}

function Get-InstalledVersion-PackageManager {
    param([string]$ToolName)
    $config = Get-ToolConfiguration -ToolName $ToolName
    Get-WingetInstalledVersion -ToolName $ToolName -PackageId $config.WingetId
}

function Get-ReleasePlan-PackageManager {
    param([string]$ToolName, [string]$InstalledVersion)
    $config = Get-ToolConfiguration -ToolName $ToolName
    $latest = Get-WingetLatestVersion -ToolName $ToolName -PackageId $config.WingetId
    $plan = @{
        Latest = $latest
        Installable = $true
        Command = if ($config.WindowsUpdateCommand) { $config.WindowsUpdateCommand } else { $config.UpdateCommand }
        Type = $config.UpdateType
        VersionLabel = 'WinGet version'
        SourceLabel = ' in WinGet'
        CurrentLabel = ' with WinGet'
    }
    $publishedAt = Get-WingetReleaseDate -ToolName $ToolName -PackageId $config.WingetId -Version $latest
    if ($publishedAt) {
        $age = Get-ReleaseAgeInfo -PublishedAt $publishedAt -CooldownDays $config.CooldownDays
        $plan.Installable = $null -ne $age -and $age.Installable
        $plan.LatestReleased = $latest
        $plan.LatestCooldown = if ($plan.Installable) { $latest } else { $null }
        $plan.AgeDays = if ($age) { $age.AgeDays } else { $null }
        $plan.RequiredAgeDays = $config.CooldownDays
        $plan.MaturityBlocked = $null -ne $age -and -not $age.Installable
        $plan.BlockReason = if ($age) { "this release requires $($config.CooldownDays) full days of cooldown." } else { 'the release age could not be verified.' }
    }
    $plan
}

function Get-WingetReleaseDate {
    param([string]$ToolName, [string]$PackageId, [string]$Version)
    $owner = Get-ResultToolId -Name $ToolName
    if (-not $owner) { return $null }
    $releases = $results.ToolState[$owner].WingetReleases
    if (-not $releases) { return $null }
    $release = $releases[$PackageId]
    if ($release -and $release.Version -eq $Version) { $release.PublishedAt }
}

function Get-WingetInstalledVersion {
    # CLI-reported versions may differ from WinGet package versions; compare like sources.
    param([string]$ToolName, [string]$PackageId)

    if (-not (Test-IsWindowsPlatform) -or
        [string]::IsNullOrWhiteSpace($PackageId) -or -not (Test-CommandExists 'winget')) {
        return $null
    }

    try {
        $metadata = @(& winget.exe list --id $PackageId -e --source winget --accept-source-agreements --disable-interactivity 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "winget list exited with code $LASTEXITCODE." }
        $packagePattern = '(?m)^[^\r\n]*[ \t]+' + [regex]::Escape($PackageId) + '[ \t]+(\d+(?:\.\d+)+)(?=[ \t]|\r?$)'
        $versionMatch = [regex]::Match(($metadata -join "`n"), $packagePattern)
        if (-not $versionMatch.Success) { throw 'Could not parse the installed package version from winget output.' }
        $versionMatch.Groups[1].Value
    } catch {
        Write-Warning "  Could not check installed $ToolName in WinGet: $_"
        $null
    }
}

function Get-WingetLatestVersion {
    param([string]$ToolName, [string]$PackageId)

    if (-not (Test-IsWindowsPlatform) -or [string]::IsNullOrWhiteSpace($PackageId)) {
        return $null
    }
    if (-not (Test-CommandExists 'winget')) {
        Write-Warning "  Could not check $ToolName in WinGet: winget not found"
        return $null
    }

    try {
        $metadata = @(& winget show --id $PackageId -e --source winget --accept-source-agreements --disable-interactivity 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "winget show exited with code $LASTEXITCODE. Output: $($metadata -join ' ')"
        }
        $metadataText = $metadata -join "`n"
        $versionMatch = [regex]::Match($metadataText, '(?m)^Version:\s*(\S+)\s*$')
        if (-not $versionMatch.Success) {
            throw 'Could not parse the package version from winget output.'
        }
        $version = $versionMatch.Groups[1].Value
        $owner = Get-ResultToolId -Name $ToolName
        if ($owner) {
            $state = Get-ToolState -ToolId $owner
            if (-not $state.WingetReleases) { $state.WingetReleases = @{} }
            $dateMatch = [regex]::Match($metadataText, '(?m)^\s*Release Date:\s*(\S+)\s*$')
            $state.WingetReleases[$PackageId] = @{ Version = $version; PublishedAt = if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { $null } }
        }
        $version
    } catch {
        $message = "Could not check $ToolName in WinGet. $(Get-DetailedErrorMessage $_)"
        Write-Warning "  $message"
        $results.Errors += $message
        $null
    }
}

function Test-WingetNoUpdateResult {
    param(
        [Parameter(Mandatory)][object]$Action,
        [int]$ExitCode,
        [string]$OutputText = ''
    )

    $wingetNoUpdateCodes = @(-1978335212, -1978335189, -1978335215)
    $isWingetCommand = $Action.Type -like 'winget*' -or $Action.Command -match '(^|\s)winget(\s|$)'
    $isWingetCommand -and (
        ($ExitCode -in $wingetNoUpdateCodes) -or
        $OutputText -match 'No applicable upgrade found' -or
        $OutputText -match 'No newer package version(s)? found' -or
        $OutputText -match 'No available upgrade found' -or
        $OutputText -match 'No installed package found matching'
    )
}

function Invoke-WingetCommand {
    param([string]$Command, [string]$Type)

    # Reject compound shell syntax rather than silently flattening it into process args.
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$null, [ref]$parseErrors)
    $statements = @($ast.EndBlock.Statements)
    if ($parseErrors.Count -or $statements.Count -ne 1 -or
        $statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        $statements[0].PipelineElements.Count -ne 1 -or
        $statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandAst] -or
        $statements[0].PipelineElements[0].Redirections.Count -gt 0) {
        throw "Expected a single winget command: $Command"
    }
    $tokens = @([System.Management.Automation.PSParser]::Tokenize($Command, [ref]$parseErrors) | Where-Object {
        $_.Type -in @('Command', 'CommandArgument', 'CommandParameter', 'Number', 'String')
    })
    if ($parseErrors.Count -gt 0 -or $tokens.Count -lt 2 -or $tokens[0].Content -notmatch '^winget(?:\.exe)?$') {
        throw "Could not parse winget command: $Command"
    }

    # Capture both streams and the native process exit code, cleaning temporary files
    # even when process creation fails. Approval is handled by the action caller.
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $processArgs = @{
            FilePath               = $tokens[0].Content
            ArgumentList           = @($tokens[1..($tokens.Count - 1)].Content)
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
        }
        $process = Start-Process @processArgs
        $output = @(
            Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue
            Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue
        ) -join "`n"
        return @{ Output = $output.Trim(); ExitCode = $process.ExitCode }
    } finally {
        Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}
