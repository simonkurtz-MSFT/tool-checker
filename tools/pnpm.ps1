#Requires -Version 7.0

# Update and refresh the active pnpm command; an npm-global copy may be shadowed on PATH.
#region Public entry points
function Test-Tool {
    param([string]$Progress)

    $toolName = 'pnpm'
    Test-StandardTool -ToolName $toolName -Progress $Progress
    if ($SkipUpdate -or [string]::IsNullOrWhiteSpace($env:PNPM_HOME)) { return }
    $update = $results.AvailableUpdates | Where-Object { $_.ToolId -eq 'pnpm' } | Select-Object -First 1
    if (-not $update) { return }

    $command = Get-Command -Name $toolsConfig[$toolName].Command -ErrorAction SilentlyContinue
    if (-not $command.Source) { return }
    $commandDirectory = Split-Path -Parent $command.Source
    $homeDirectory = $env:PNPM_HOME.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($commandDirectory -in @($homeDirectory, (Join-Path $homeDirectory 'bin'))) {
        $update.Command = "pnpm self-update $($results.Tools[$toolName].Latest)"
        $update.Type = 'self-update'
    }
}

function Refresh-ToolStatus {
    param([string]$ToolName)
    $config = $toolsConfig[$ToolName]
    Refresh-StandardVersion -ToolName $ToolName -Config $config
}
#endregion

#region Private helpers
#endregion
