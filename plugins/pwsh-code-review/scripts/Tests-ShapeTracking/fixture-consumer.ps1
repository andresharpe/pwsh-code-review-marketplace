function Use-Widget {
    [CmdletBinding()]
    param()
    $w = Get-Widget
    Write-Output $w.Color
}
