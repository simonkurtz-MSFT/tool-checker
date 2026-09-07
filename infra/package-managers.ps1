# Explicit package-manager dependency loading and operation dispatch. Package manager
# filenames come from selected catalog entries; loading never executes operations.
function Get-PackageManagerDefinitionFiles {
    param([System.Collections.IDictionary]$ToolsConfiguration, [string]$Directory)
    $files = @($ToolsConfiguration.Values | Where-Object { $_.Enabled } | ForEach-Object {
        $_.PackageManagerFiles
        if ($IsWindows -or $env:OS -eq 'Windows_NT') { $_.WindowsPackageManagerFiles }
    } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($file in $files) {
        if ($file -notmatch '^[a-z0-9][a-z0-9-]*\.ps1$') { throw "Invalid package manager filename: $file" }
        $path = Join-Path $Directory $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Package manager file not found: $path" }
        [PSCustomObject]@{ Id = $file; FullName = $path }
    }
}

function Get-ConfiguredPackageManager {
    param([object]$Configuration, [string]$Operation)
    $platformProperty = "Windows${Operation}PackageManager"
    if (($IsWindows -or $env:OS -eq 'Windows_NT') -and $Configuration[$platformProperty]) {
        return $Configuration[$platformProperty]
    }
    $Configuration["${Operation}PackageManager"]
}

function Invoke-PackageManagerOperation {
    param([string]$PackageManager, [string]$Operation, [hashtable]$Arguments = @{})
    $definitions = $script:PackageManagerDefinitions[$PackageManager]
    $entryPoint = "${Operation}-PackageManager"
    if (-not $definitions -or -not $definitions.ContainsKey($entryPoint)) {
        throw "Package manager '$PackageManager' does not define '$entryPoint'."
    }
    # Shared helpers are already loaded; colliding operation names exist only here.
    . ([scriptblock]::Create((@($definitions.Keys | Where-Object { $_ -like '*-PackageManager' } | ForEach-Object { $definitions[$_] }) -join "`n`n")))
    & $entryPoint @Arguments
}

function Read-DefinitionRegistry {
    # Parse without executing. Store source text so both main and workers load the
    # same definitions, without capturing live session functions or test mocks.
    param([object[]]$Files)
    $registry = @{}
    foreach ($file in $Files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Invalid definition file: $($file.FullName): $($parseErrors -join '; ')" }
        if ($ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or $ast.ParamBlock -or
            @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count) {
            throw "Definition file must contain functions only: $($file.FullName)"
        }
        $definitions = @{}
        foreach ($definition in $ast.EndBlock.Statements) { $definitions[$definition.Name] = $definition.Extent.Text }
        $registry[$file.Id] = $definitions
    }
    $registry
}