function Use-WidgetIndex {
    [CmdletBinding()]
    param()
    $w = Get-Widget
    Write-Output $w['Color']
}
