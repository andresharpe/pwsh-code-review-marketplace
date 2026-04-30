// PWSH-JS-007 positive fixture: truthy check on raw value, render the
// sanitized version. When sanitize() strips everything, the conditional
// fired but the rendered output is blank.

function sanitize(value) {
    return value.replace(/<[^>]*>/g, '');
}

export function renderTitle(target, raw) {
    if (raw) {
        target.textContent = sanitize(raw);
    }
}
