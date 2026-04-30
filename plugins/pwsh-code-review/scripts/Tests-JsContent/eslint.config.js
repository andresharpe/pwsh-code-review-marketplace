// ESLint flat config used by the Tests-JsContent self-test runner.
// Kept minimal: only rules that the stock eslint package can enforce
// without extra plugins. The agent (js-content-agent.md) covers the
// rest. This config is here so Run.ps1 can verify the eslint
// integration end-to-end without depending on third-party plugins.

export default [
    {
        // .cjs is intentionally NOT in the pattern: this config forces
        // sourceType: 'module', which would produce avoidable parse errors
        // on a CommonJS .cjs fixture if one were ever added. If a .cjs
        // fixture is needed, add a second config block with sourceType: 'script'.
        files: ['**/*.js', '**/*.mjs'],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: 'module',
            globals: {
                window: 'readonly',
                document: 'readonly',
                fetch: 'readonly',
                console: 'readonly',
                URL: 'readonly',
                URLSearchParams: 'readonly',
                AbortController: 'readonly',
                localStorage: 'readonly',
                location: 'readonly',
                setTimeout: 'readonly',
                setInterval: 'readonly',
                clearTimeout: 'readonly',
                clearInterval: 'readonly',
                Object: 'readonly',
                String: 'readonly',
                Error: 'readonly'
            }
        },
        rules: {
            // Catches PWSH-JS-004's `==` / `!=` substring (the bare-falsy
            // half is too context-dependent for stock eslint to flag).
            eqeqeq: 'error',
            // Catches truly bare globals (the harder case PWSH-JS-001
            // covers — assignment to window.X — is out of scope for stock
            // eslint and stays the agent's job).
            'no-undef': 'error'
        }
    }
];
