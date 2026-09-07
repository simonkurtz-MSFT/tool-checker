# Shared result schema and catalog-ID ownership. Tool-specific inventory belongs
# under ToolState; visible rows and action arrays remain generic for merge/rendering.
function Get-ToolState {
    param([Parameter(Mandatory)][string]$ToolId)
    if (-not $results.ToolState.ContainsKey($ToolId)) { $results.ToolState[$ToolId] = @{} }
    $results.ToolState[$ToolId]
}

function Get-ResultToolId {
    param([string]$Name)
    if ($results.Tools.ContainsKey($Name) -and $results.Tools[$Name].ToolId) { return $results.Tools[$Name].ToolId }
    if ($toolsConfig.Contains($Name)) { return $toolsConfig[$Name].Id }
    $update = $results.AvailableUpdates | Where-Object Name -eq $Name | Select-Object -First 1
    if ($update.ToolId) { return $update.ToolId }
    # During tool dispatch, PowerShell's parent scope supplies the owning ToolId.
    $ToolId
}

function Get-OwnedConfiguration {
    param([string]$ToolId)
    $toolsConfig.Values | Where-Object Id -eq $ToolId | Select-Object -First 1
}

function Set-ToolResultOwnership {
    param([string]$ToolId, [hashtable]$PreviousRows = @{})
    $config = Get-OwnedConfiguration -ToolId $ToolId
    # Stamp only new/replaced unowned rows; unrelated pre-existing rows stay untouched.
    foreach ($entry in $results.Tools.GetEnumerator()) {
        if (-not $entry.Value.ToolId -and (-not $PreviousRows.ContainsKey($entry.Key) -or -not [object]::ReferenceEquals($PreviousRows[$entry.Key], $entry.Value))) {
            $entry.Value.ToolId = $ToolId
            $entry.Value.ItemId = $entry.Key
            $entry.Value.ReleaseNotesUrl = $config.ReleaseNotesUrl
        }
    }
}
function New-ToolCheckResults {
    # Each invocation gets fresh collections, including every worker's isolated result.
    @{
        Tools                   = @{}
        ToolState              = @{}
        NotInstalled            = @()
        Updates                 = @()
        Errors                  = @()
        UpdateFailed            = @()
        AvailableUpdates        = @()
        MaturityBlockedUpdates  = @()
        RegistryChecks          = @()
    }
}
