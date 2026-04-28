# This is the default template for pattern-error-handling.
# Replace with a real canonical example from your codebase when one is available.
#
# What to look for:
#   - $ErrorActionPreference set explicitly at top
#   - Set-StrictMode invoked
#   - try/catch only where the function can actually do something with the error
#   - Empty catch is forbidden
#   - Write-Error -ErrorAction Stop with -Category and -ErrorId, not bare throw "string"
#   - Resource cleanup in finally where applicable
#   - The error has a stable ID so callers can pattern-match if needed

function Invoke-ExampleWithErrorHandling {
    <#
    .SYNOPSIS
        Demonstrates the project's error-handling conventions.

    .DESCRIPTION
        Reads a file, parses it as JSON, returns the parsed object.
        Errors are surfaced as terminating, with stable error IDs and
        helpful targeting information.

    .PARAMETER Path
        The path to the file to read.

    .EXAMPLE
        Invoke-ExampleWithErrorHandling -Path ./config.json

    .OUTPUTS
        [pscustomobject]
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Path)) {
        # Typed, stable error. The error ID lets tests assert on it without
        # parsing the message string.
        $writeErrorParams = @{
            Message      = "Configuration file not found: $Path"
            Category     = [System.Management.Automation.ErrorCategory]::ObjectNotFound
            ErrorId      = 'ConfigFileNotFound'
            TargetObject = $Path
            ErrorAction  = 'Stop'
        }
        Write-Error @writeErrorParams
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $reader = [System.IO.StreamReader]::new($stream)
        $content = $reader.ReadToEnd()

        try {
            return $content | ConvertFrom-Json -ErrorAction Stop
        } catch [System.Text.Json.JsonException], [System.ArgumentException] {
            # Catch parse failure specifically and re-raise with project-specific shape.
            $writeErrorParams = @{
                Message      = "Failed to parse JSON in ${Path}: $($_.Exception.Message)"
                Category     = [System.Management.Automation.ErrorCategory]::ParserError
                ErrorId      = 'ConfigFileParseError'
                TargetObject = $Path
                Exception    = $_.Exception
                ErrorAction  = 'Stop'
            }
            Write-Error @writeErrorParams
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}
