// PWSH-JS-009 negative fixture: keys are validated against an explicit
// allowlist before being copied. Bad keys (__proto__, constructor) cannot
// reach `target`.

const ALLOWED_KEYS = ['theme', 'autoSave', 'fontSize'];

export async function loadOptions(target) {
    const r = await fetch('/api/options');
    const incoming = await r.json();
    for (const key of ALLOWED_KEYS) {
        if (Object.prototype.hasOwnProperty.call(incoming, key)) {
            target[key] = incoming[key];
        }
    }
    return target;
}
