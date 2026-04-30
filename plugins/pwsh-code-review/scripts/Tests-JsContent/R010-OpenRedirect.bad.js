// PWSH-JS-010 positive fixture: window.location set from a URL parameter
// with no allowlist check. Attacker crafts ?next=https://evil.example,
// user clicks the trusted-looking link, lands on evil.

export function followNext() {
    const params = new URLSearchParams(window.location.search);
    const next = params.get('next');
    if (next) {
        window.location.href = next;
    }
}
