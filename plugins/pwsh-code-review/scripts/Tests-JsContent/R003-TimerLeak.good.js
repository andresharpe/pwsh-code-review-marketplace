// PWSH-JS-003 negative fixture: handle stored, returned cleanup clears it.

export function startPolling() {
    const handle = setInterval(() => {
        fetch('/api/heartbeat');
    }, 5000);
    return () => clearInterval(handle);
}
