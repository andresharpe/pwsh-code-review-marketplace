// PWSH-JS-010 negative fixture: only allow same-origin or explicitly
// allowlisted destinations.

const ALLOWED_HOSTS = new Set([location.host]);

export function followNext() {
    const params = new URLSearchParams(window.location.search);
    const next = params.get('next');
    if (!next) {
        return;
    }
    let target;
    try {
        target = new URL(next, window.location.origin);
    } catch {
        return;
    }
    if (!ALLOWED_HOSTS.has(target.host)) {
        return;
    }
    window.location.href = target.href;
}
