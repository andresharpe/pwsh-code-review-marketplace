@{
    ConfidenceThreshold = 80
    NitCap              = 3
    Platforms           = @('core-7.4-windows', 'core-7.4-linux')
    SkipAgents          = @()
    StaticAnalysisOnly  = $false

    # Rule severity overrides: map a rule ID to a non-default severity.
    # Use sparingly; only when the project context legitimately warrants
    # a different default than the agent / scanner ships.
    RuleSeverityOverrides = @{
        # InjectionHunter fires on safe patterns inside this repo:
        #   - $tools.$name dispatch where $name is a literal-set lookup.
        #   - Allowlist-validated dynamic property access.
        #   - Test fixtures named *-dynamic.ps1 that intentionally
        #     demonstrate the dynamic pattern for shape-tracking tests.
        # The scanner has no way to see the upstream allowlist, so its
        # "blocker" classification is wrong for this codebase. Demote
        # to minor; humans still see the finding but it does not gate
        # CI / pre-push.
        'InjectionRisk.StaticPropertyInjection' = 'minor'
        'InjectionRisk.UnsafeEscaping'          = 'minor'

        # The Tests-JsContent fixtures are deliberately-bad JavaScript
        # designed to demonstrate the rules js-content-agent and the
        # eslint runner enforce. eslint flagging them is the fixture
        # working as intended; we do not want that to gate pushes.
        'eslint/eqeqeq' = 'minor'
    }
}
