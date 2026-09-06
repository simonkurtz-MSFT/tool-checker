#Requires -Version 7.0

#region Public entry points
function Invoke-ToolInstall {
    $output = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not (Test-CommandExists 'winget')) {
            return @{ Output = 'winget is required to install uv on Windows.'; ExitCode = 1 }
        }

        $uvCommands = @(Get-Command uv -All -ErrorAction SilentlyContinue)
        $uvPaths = @($uvCommands | ForEach-Object Source | Where-Object { $_ } | Select-Object -Unique)

        if ($uvPaths -match '\\pipx\\' -and (Test-CommandExists 'pipx')) {
            $pipxOutput = pipx uninstall uv 2>&1 | Out-String
            if ($pipxOutput) { $output.Add($pipxOutput.Trim()) }
        }
        if ($uvPaths -match '\\.cargo\\bin\\' -and (Test-CommandExists 'cargo')) {
            $cargoOutput = cargo uninstall uv 2>&1 | Out-String
            if ($cargoOutput) { $output.Add($cargoOutput.Trim()) }
        }

        $uninstall = Invoke-ToolCommand -Command 'winget uninstall --id astral-sh.uv -e --silent --disable-interactivity' -Type 'winget'
        if ($uninstall.Output) { $output.Add($uninstall.Output) }

        foreach ($binDirectory in @(
            (Join-Path $env:USERPROFILE '.local\bin'),
            (Join-Path $env:USERPROFILE '.cargo\bin')
        )) {
            foreach ($binary in @('uv.exe', 'uvx.exe', 'uvw.exe')) {
                $binaryPath = Join-Path $binDirectory $binary
                if (Test-Path -LiteralPath $binaryPath) {
                    Remove-Item -LiteralPath $binaryPath -Force -ErrorAction Stop
                    $output.Add("Removed $binaryPath")
                }
            }
        }

        $install = Invoke-ToolCommand -Command 'winget install --id astral-sh.uv -e --source winget --silent --disable-interactivity --force' -Type 'winget'
        if ($install.Output) { $output.Add($install.Output) }
        return @{ Output = ($output -join "`n"); ExitCode = $install.ExitCode }
    } catch {
        $output.Add((Get-DetailedErrorMessage $_))
        return @{ Output = ($output -join "`n"); ExitCode = 1 }
    }
}
#endregion

#region Private helpers
#endregion
