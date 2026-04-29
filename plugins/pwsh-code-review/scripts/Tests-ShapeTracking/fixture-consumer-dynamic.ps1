function Use-WidgetDynamic {
    [CmdletBinding()]
    param([string]$Prop = 'Color')
    $w = Get-Widget
    Write-Output $w.($Prop)
}
