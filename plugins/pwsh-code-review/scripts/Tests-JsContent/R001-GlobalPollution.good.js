// PWSH-JS-001 negative fixture: same effect, no global pollution.
// State lives in a module-scoped variable; consumers import it.

let appState = { ready: false };

export function init() {
    appState.ready = true;
}

export function getState() {
    return appState;
}
