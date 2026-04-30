@{
    ConfidenceThreshold = 80
    NitCap              = 3
    Platforms           = @('core-7.4-windows', 'core-7.4-linux')
    SkipAgents          = @()
    StaticAnalysisOnly  = $false

    # Rule severity overrides: map a rule ID to a non-default severity.
    # Use sparingly; only when the project context legitimately warrants
    # a different default than the agent / scanner ships.
    RuleSeverityOverrides = @{}
}
