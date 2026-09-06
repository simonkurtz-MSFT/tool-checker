# Selected Windows package packageManager: compare package versions, run single WinGet
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
    @{
        Latest = Get-WingetLatestVersion -ToolName $ToolName -PackageId $config.WingetId
        Installable = $true
        Command = if ($config.WindowsUpdateCommand) { $config.WindowsUpdateCommand } else { $config.UpdateCommand }
        Type = $config.UpdateType
        VersionLabel = 'WinGet version'
        SourceLabel = ' in WinGet'
        CurrentLabel = ' with WinGet'
    }
}

function Get-WingetInstalledVersion {
    # CLI-reported versions may differ from WinGet package versions; compare like sources.
    param([string]$ToolName, [string]$PackageId)

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT') -or
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

    if (-not ($IsWindows -or $env:OS -eq 'Windows_NT') -or [string]::IsNullOrWhiteSpace($PackageId)) {
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
        $versionMatch.Groups[1].Value
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
