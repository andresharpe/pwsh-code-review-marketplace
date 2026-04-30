// PWSH-JS-003 positive fixture: setInterval handle is discarded.
// Each call to startPolling adds another interval; nothing ever clears it.

export function startPolling() {
    setInterval(() => {
        fetch('/api/heartbeat');
    }, 5000);
}
