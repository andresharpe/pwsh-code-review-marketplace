// PWSH-JS-006 positive fixture: JSON.parse on untrusted localStorage value
// with no try/catch. Malformed JSON throws and crashes the caller.

export function loadDraft() {
    const raw = localStorage.getItem('draft');
    return JSON.parse(raw);
}
