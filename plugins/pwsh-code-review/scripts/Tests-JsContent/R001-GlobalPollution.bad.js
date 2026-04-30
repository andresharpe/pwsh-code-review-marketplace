// PWSH-JS-001 positive fixture: global pollution
// Sets a bare global that another module reads. The agent should flag this.

function init() {
    window.appState = { ready: false };
    window.appState.ready = true;
}

// Somewhere else in the corpus another module reads `window.appState`.
init();
