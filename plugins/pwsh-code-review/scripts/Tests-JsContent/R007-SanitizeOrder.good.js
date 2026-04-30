// PWSH-JS-007 negative fixture: sanitize first, check the sanitized value.

function sanitize(value) {
    return value.replace(/<[^>]*>/g, '');
}

export function renderTitle(target, raw) {
    const safe = sanitize(raw ?? '');
    if (safe) {
        target.textContent = safe;
    }
}
