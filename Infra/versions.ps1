# Shared version rules and owner-aware comparison. Tool overrides must be pure and
# return -1, 0, or 1; callers without an owner use the default semantic comparison.
function ConvertTo-CanonicalSemanticVersion {
    param([string]$Version)
    if ($Version -match '^(\d+(?:\.\d+)+)-(\d+)$') {
        $Version = "$($Matches[1]).$($Matches[2])"
    }
    if ($Version -notmatch '^\d+(?:\.\d+)+$') { return $Version }

    $parts = [System.Collections.Generic.List[string]]@($Version -split '\.')
    while ($parts.Count -gt 3 -and $parts[$parts.Count - 1] -eq '0') {
        $parts.RemoveAt($parts.Count - 1)
    }
    $parts -join '.'
}

function Compare-SemanticVersions {
    param([string]$Version1, [string]$Version2)
    $Version1 = ConvertTo-CanonicalSemanticVersion $Version1
    $Version2 = ConvertTo-CanonicalSemanticVersion $Version2
    try {
        $v1 = [version]$Version1; $v2 = [version]$Version2
        if ($v1 -lt $v2) { -1 } elseif ($v1 -gt $v2) { 1 } else { 0 }
    } catch {
        if ($Version1 -lt $Version2) { -1 } elseif ($Version1 -gt $Version2) { 1 } else { 0 }
    }
}

function Compare-OwnedToolVersions {
    param([string]$Version1, [string]$Version2, [string]$ToolName)
    $owner = if ($ToolName) { Get-ResultToolId -Name $ToolName }
    if ($owner -and $script:ToolDefinitions.ContainsKey($owner) -and
        $script:ToolDefinitions[$owner].ContainsKey('Compare-ToolVersions')) {
        $state = $results.ToolState[$owner]
        $comparison = Invoke-ToolEntryPoint -ToolId $owner -EntryPoint 'Compare-ToolVersions' -Arguments @{
            Version1 = $Version1
            Version2 = $Version2
            Version1Source = $state.InstalledVersionSource
            Version2Source = $state.LatestVersionSource
        }
        if ($comparison -isnot [int] -or $comparison -notin @(-1, 0, 1)) {
            throw "Tool '$owner' Compare-ToolVersions must return exactly one integer: -1, 0, or 1."
        }
        return $comparison
    }
    Compare-SemanticVersions -Version1 $Version1 -Version2 $Version2
}

function Test-UpdateAvailable {
    param([string]$InstalledVersion, [string]$LatestVersion, [string]$ToolName)
    if ([string]::IsNullOrWhiteSpace($LatestVersion)) { return $false }
    (Compare-OwnedToolVersions -Version1 $InstalledVersion -Version2 $LatestVersion -ToolName $ToolName) -eq -1
}

function Test-IsProductionVersion {
    param([string]$Version)
    -not [string]::IsNullOrWhiteSpace($Version) -and $Version.Trim() -match '^v?\d+\.\d+\.\d+(?:\.0)?$'
}