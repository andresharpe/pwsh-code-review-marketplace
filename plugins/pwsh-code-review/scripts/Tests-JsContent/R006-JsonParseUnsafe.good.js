// PWSH-JS-006 negative fixture: JSON.parse wrapped in try/catch with a
// safe fallback.

export function loadDraft() {
    const raw = localStorage.getItem('draft');
    if (!raw) {
        return null;
    }
    try {
        return JSON.parse(raw);
    } catch {
        return null;
    }
}
