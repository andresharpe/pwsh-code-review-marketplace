// PWSH-JS-005 negative fixture: try/catch + response.ok check before
// reading the body.

export async function loadConfig() {
    try {
        const r = await fetch('/api/config');
        if (!r.ok) {
            throw new Error(`config fetch failed: ${r.status}`);
        }
        return await r.json();
    } catch (err) {
        console.error('loadConfig failed', err);
        return null;
    }
}
