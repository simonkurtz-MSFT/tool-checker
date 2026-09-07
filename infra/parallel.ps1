# Parallel inventory checks: build isolated workers, capture their host output,
# enforce timeouts, and merge results in catalog order. No actions execute here.
function Get-ParallelCheckFunctionBlock {
    param(
        [Parameter(Mandatory)][string]$ScriptContent,
        [Parameter(Mandatory)][hashtable]$ToolsConfiguration
    )

    # Only checking dependencies cross into workers; startup/readers/renderers stay out.
    $functionNames = @(
        'Invoke-ToolEntryPoint','Get-ConfiguredPackageManager','Invoke-PackageManagerOperation','Register-ReleasePlan',
        'Get-ResultToolId','Get-OwnedConfiguration','Set-ToolResultOwnership','Get-ToolState','Resolve-ActionMetadata',
        'New-ToolCheckResults','Write-Header','Write-Success','Write-Warning','Write-Error',
        'Test-CommandExists','Get-DetailedErrorMessage','Get-ToolConfiguration','Get-CommandVersion',
        'ConvertTo-CanonicalSemanticVersion','Compare-SemanticVersions','Compare-OwnedToolVersions','Test-UpdateAvailable',
        'Test-IsProductionVersion','Set-LatestToolVersion',
        'Invoke-SafeApiRequest','Add-NotInstalledTool','Add-AvailableUpdate','Register-ToolUpdate',
        'Test-StandardTool','Get-InstalledVersionFromOutput','Get-LatestVersionFromApi','Get-UpdateCommand','Get-StandardToolUpdates'
    )
    $functionNames += @($ToolsConfiguration.Values | Where-Object { $_.CheckType -eq 'custom' } | ForEach-Object { $_.CustomFunction })

    $outputContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'output.ps1') -Raw
    $configurationContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'configuration.ps1') -Raw
    $sourcePaths = @('checks.ps1','versions.ps1','package-managers.ps1','results.ps1','runtime.ps1','actions.ps1')
    $sharedContent = ($sourcePaths | ForEach-Object { Get-Content -LiteralPath (Join-Path $PSScriptRoot $_) -Raw }) -join "`n"
    $ast = [System.Management.Automation.Language.Parser]::ParseInput("$ScriptContent`n$sharedContent`n$outputContent`n$configurationContent", [ref]$null, [ref]$null)
    $functionDefinitions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $definitions = @($functionDefinitions | Where-Object { $_.Name -in $functionNames } | ForEach-Object { $_.Extent.Text })
    $serializedDefinitions = (ConvertTo-Json -InputObject $script:ToolDefinitions -Depth 5 -Compress).Replace("'", "''")
    $definitions += "`$script:ToolDefinitions = ConvertFrom-Json -AsHashtable -InputObject '$serializedDefinitions'"
    $serializedPackageManagers = (ConvertTo-Json -InputObject $script:PackageManagerDefinitions -Depth 5 -Compress).Replace("'", "''")
    $definitions += "`$script:PackageManagerDefinitions = ConvertFrom-Json -AsHashtable -InputObject '$serializedPackageManagers'"
    foreach ($packageManager in $script:PackageManagerDefinitions.Values) {
        $definitions += @($packageManager.Keys | Where-Object { $_ -notlike '*-PackageManager' } | ForEach-Object { $packageManager[$_] })
    }
    $definitions -join "`n`n"
}

function New-ParallelCheckTimeoutResult {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutSec
    )

    $timeoutResult = New-ToolCheckResults
    $timeoutResult.Index = $Index
    $timeoutResult.Output = @()
    $timeoutResult.Tools[$Name] = @{ Installed = 'unknown'; Latest = ''; CheckTimedOut = $true }
    $timeoutResult.Errors = @("$Name check timed out after ${TimeoutSec}s")
    $timeoutResult
}

function Merge-ParallelCheckResult {
    param([Parameter(Mandatory)][object]$CheckResult)

    foreach ($line in $CheckResult.Output) { Write-Host $line }
    foreach ($entry in $CheckResult.Tools.GetEnumerator()) { $results.Tools[$entry.Key] = $entry.Value }
    foreach ($entry in $CheckResult.ToolState.GetEnumerator()) { $results.ToolState[$entry.Key] = $entry.Value }
    $results.NotInstalled            += $CheckResult.NotInstalled
    $results.Updates                 += $CheckResult.Updates
    $results.Errors                  += $CheckResult.Errors
    $results.UpdateFailed            += $CheckResult.UpdateFailed
    $results.AvailableUpdates        += $CheckResult.AvailableUpdates
    $results.MaturityBlockedUpdates  += $CheckResult.MaturityBlockedUpdates
}

function Get-ParallelCheckWorkerScript {
    {
        param($fnBlock, $checkStr, $progress, $idx,
            $toolsConfig, $SkipUpdate, $PlatformKey, $ReleaseCooldownDays, $ApiRequestTimeout,
            $ColorReset, $ColorGreen, $ColorYellow, $ColorRed, $ColorCyan, $ColorBlue)

        $Global:__rs_outputLines = [System.Collections.Generic.List[string]]::new()
        $Global:toolsConfig = $toolsConfig
        $Global:SkipUpdate = $SkipUpdate
        $Global:PlatformKey = $PlatformKey
        $Global:ReleaseCooldownDays = $ReleaseCooldownDays
        $Global:ApiRequestTimeout = $ApiRequestTimeout
        $Global:ColorReset = $ColorReset
        $Global:ColorGreen = $ColorGreen
        $Global:ColorYellow = $ColorYellow
        $Global:ColorRed = $ColorRed
        $Global:ColorCyan = $ColorCyan
        $Global:ColorBlue = $ColorBlue

        # Capture host-only messages so concurrent checks cannot interleave console lines.
        $writeHostOverride = @'
function Write-Host {
    $Global:__rs_outputLines.Add(($args -join ' '))
}
$script:PlatformKey = $Global:PlatformKey
$script:ReleaseCooldownDays = $Global:ReleaseCooldownDays
$script:ApiRequestTimeout = $Global:ApiRequestTimeout
$results = $Global:results
$toolsConfig = $Global:toolsConfig
$SkipUpdate = $Global:SkipUpdate
$ColorReset = $Global:ColorReset
$ColorGreen = $Global:ColorGreen
$ColorYellow = $Global:ColorYellow
$ColorRed = $Global:ColorRed
$ColorCyan = $Global:ColorCyan
$ColorBlue = $Global:ColorBlue
'@
        $combinedBlock = $writeHostOverride + "`n`n" + $fnBlock
        . ([scriptblock]::Create($combinedBlock))
        $Global:results = New-ToolCheckResults
        $results = $Global:results

        # Check descriptors reserve $args[0] for the progress label, not tool arguments.
        try { Invoke-Expression ($checkStr -replace '\$args\[0\]', "'$progress'") }
        catch { $Global:__rs_outputLines.Add("  `e[31m✗ Check error: $_`e[0m") }

        @{
            Index                   = $idx
            Output                  = $Global:__rs_outputLines.ToArray()
            Tools                   = $Global:results.Tools
            ToolState              = $Global:results.ToolState
            NotInstalled            = $Global:results.NotInstalled
            Updates                 = $Global:results.Updates
            Errors                  = $Global:results.Errors
            AvailableUpdates        = $Global:results.AvailableUpdates
            MaturityBlockedUpdates  = $Global:results.MaturityBlockedUpdates
            UpdateFailed            = $Global:results.UpdateFailed
        }
    }
}

function Invoke-ParallelChecks {
    param([array]$Checks, [int]$Total, [int]$TimeoutSec = 60)
    if ($Checks.Count -eq 0) { return }

    # Extract shared script helpers and the loaded tool-file functions for workers.
    $scriptContent = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'tool-checker.ps1') -Raw
    $fnBlock = Get-ParallelCheckFunctionBlock -ScriptContent $scriptContent -ToolsConfiguration $toolsConfig

    # Build runspace pool — cap at check count but no more than logical CPUs
    $maxThreads = [Math]::Min($Checks.Count, [System.Environment]::ProcessorCount)
    $pool = $null
    $workers = [System.Collections.Generic.List[System.Management.Automation.PowerShell]]::new()
    $operationError = $null

    # Snapshot resolved state as positional worker arguments; do not rerun bootstrap.
    $snap_toolsConfig  = $toolsConfig
    $snap_SkipUpdate   = $SkipUpdate
    $snap_PlatformKey  = $script:PlatformKey
    $snap_ReleaseCooldownDays = $script:ReleaseCooldownDays
    $snap_ColorReset   = $ColorReset
    $snap_ColorGreen   = $ColorGreen
    $snap_ColorYellow  = $ColorYellow
    $snap_ColorRed     = $ColorRed
    $snap_ColorCyan    = $ColorCyan
    $snap_ColorBlue    = $ColorBlue

    $padWidth    = $Total.ToString().Length
    $descriptionWidth = ('Completed with errors: ').Length + ($Checks | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $durationWidth = [Math]::Max(6, ('{0:N1}s' -f $TimeoutSec).Length)
    $successIcon = [char]0x2713
    $threadStatusLines = [string[]]::new($Checks.Count)
    $parallelStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $supportsStatusUpdates = $false
    try {
        $supportsStatusUpdates = $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected
    } catch { }
    $renderThreadStatuses = {
        if (-not $supportsStatusUpdates) { return }
        $elapsedSeconds = [Math]::Floor($parallelStopwatch.Elapsed.TotalSeconds)
        $Host.UI.Write("`e[s`e[$($threadStatusLines.Count + 2)A")
        $Host.UI.Write("`e[2K`r  Elapsed: ${elapsedSeconds}s`n")
        $Host.UI.Write("`e[2K`r`n")
        foreach ($line in $threadStatusLines) {
            $Host.UI.Write("`e[2K`r$line`n")
        }
        $Host.UI.Write("`e[u")
    }

    $collectedResults = @{}
    try {
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxThreads)
        $pool.Open()
        if ($supportsStatusUpdates) { $Host.UI.Write("`e[?25l") }
        Write-Host "  Elapsed: 0s"
        Write-Host ""
        $runningJobs = @()
        for ($i = 0; $i -lt $Checks.Count; $i++) {
            $idx      = $i
            $toolName = $Checks[$i].Name
            # Pass check as string so Invoke-Expression executes it in the runspace scope
            $checkStr = $Checks[$i].Block.ToString()
            $progress = "{0,$padWidth}/{1}" -f ($i + 1), $Total

            $threadStatusLines[$i] = "  $ColorCyan⟳ [$progress] Running: $toolName$ColorReset"
            Write-Host $threadStatusLines[$i]

            $ps = [System.Management.Automation.PowerShell]::Create()
            $workers.Add($ps)
            $ps.RunspacePool = $pool

            [void]$ps.AddScript((Get-ParallelCheckWorkerScript))
            [void]$ps.AddArgument($fnBlock)
            [void]$ps.AddArgument($checkStr)
            [void]$ps.AddArgument($progress)
            [void]$ps.AddArgument($idx)
            [void]$ps.AddArgument($snap_toolsConfig)
            [void]$ps.AddArgument($snap_SkipUpdate)
            [void]$ps.AddArgument($snap_PlatformKey)
            [void]$ps.AddArgument($snap_ReleaseCooldownDays)
            [void]$ps.AddArgument($TimeoutSec)
            [void]$ps.AddArgument($snap_ColorReset)
            [void]$ps.AddArgument($snap_ColorGreen)
            [void]$ps.AddArgument($snap_ColorYellow)
            [void]$ps.AddArgument($snap_ColorRed)
            [void]$ps.AddArgument($snap_ColorCyan)
            [void]$ps.AddArgument($snap_ColorBlue)

            $runningJobs += @{ PS = $ps; Handle = $ps.BeginInvoke(); Index = $idx; StartTime = [System.Diagnostics.Stopwatch]::StartNew(); Name = $toolName }
        }

        while ($runningJobs.Count -gt 0) {
            $still = @()
            foreach ($job in $runningJobs) {
            if ($job.Handle.IsCompleted) {
                $elapsed = $job.StartTime.Elapsed
                $rawResult = $job.PS.EndInvoke($job.Handle)
                $hasErrors = $job.PS.Streams.Error.Count -gt 0
                if ($hasErrors) {
                    foreach ($err in $job.PS.Streams.Error) {
                        $results.Errors += "Parallel check error (job $($job.Index)): $err"
                    }
                }
                $job.PS.Dispose()
                [void]$workers.Remove($job.PS)
                if ($rawResult -and $rawResult.Count -gt 0) {
                    $hasErrors = $hasErrors -or $rawResult[0].Errors.Count -gt 0
                    $collectedResults[$job.Index] = $rawResult[0]
                }
                $progress = "{0,$padWidth}/{1}" -f ($job.Index + 1), $Total
                $elapsedLabel = '{0:N1}s' -f $elapsed.TotalSeconds
                if ($hasErrors) {
                    $description = "Completed with errors: $($job.Name)"
                    $threadStatusLines[$job.Index] = "  $ColorYellow! [$progress] {0,-$descriptionWidth}  {1,$durationWidth}$ColorReset" -f $description, $elapsedLabel
                } else {
                    $description = "Completed: $($job.Name)"
                    $threadStatusLines[$job.Index] = "  $ColorGreen$successIcon [$progress] {0,-$descriptionWidth}  {1,$durationWidth}$ColorReset" -f $description, $elapsedLabel
                }
                if ($supportsStatusUpdates) { & $renderThreadStatuses } else { Write-Host $threadStatusLines[$job.Index] }
            } elseif ($job.StartTime.Elapsed.TotalSeconds -ge $TimeoutSec) {
                # Kill the runspace that exceeded the timeout
                $job.PS.Stop()
                $job.PS.Dispose()
                [void]$workers.Remove($job.PS)
                # Provide a minimal result so the merge loop can handle it
                $progress = "{0,$padWidth}/{1}" -f ($job.Index + 1), $Total
                $description = "Timed out: $($job.Name)"
                $threadStatusLines[$job.Index] = "  $ColorRed✗ [$progress] {0,-$descriptionWidth}  {1,$durationWidth}$ColorReset" -f $description, "${TimeoutSec}s"
                if ($supportsStatusUpdates) { & $renderThreadStatuses } else { Write-Host $threadStatusLines[$job.Index] }
                $collectedResults[$job.Index] = New-ParallelCheckTimeoutResult -Index $job.Index -Name $job.Name -TimeoutSec $TimeoutSec
                } else {
                    $still += $job
                }
            }
            $runningJobs = $still
            if ($runningJobs.Count -gt 0) {
                if ($supportsStatusUpdates) { & $renderThreadStatuses }
                Start-Sleep -Milliseconds 250
            }
        }
    } catch {
        $operationError = $_
        throw
    } finally {
        $cleanupErrors = @()
        foreach ($worker in $workers) {
            try { $worker.Stop() } catch { $cleanupErrors += $_ }
            try { $worker.Dispose() } catch { $cleanupErrors += $_ }
        }
        $workers.Clear()
        if ($null -ne $pool) {
            try { $pool.Close() } catch { $cleanupErrors += $_ }
            try { $pool.Dispose() } catch { $cleanupErrors += $_ }
        }
        $parallelStopwatch.Stop()
        if ($supportsStatusUpdates) {
            try { $Host.UI.Write("`e[?25h") } catch { $cleanupErrors += $_ }
        }
        if (-not $operationError -and $cleanupErrors.Count -gt 0) { throw $cleanupErrors[0] }
    }
    Write-Host ""

    # Print output and merge results in original order
    for ($i = 0; $i -lt $Checks.Count; $i++) {
        if (-not $collectedResults.ContainsKey($i)) { continue }
        Merge-ParallelCheckResult -CheckResult $collectedResults[$i]
    }
}
