function Get-Widget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        Id    = 1
        Name  = 'a'
        Color = 'red'
    }
}
