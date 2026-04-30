// PWSH-JS-005 positive fixture: fetch chain has no error path and no
// response.ok check.

export async function loadConfig() {
    const r = await fetch('/api/config');
    const config = await r.json();
    return config;
}
