// PWSH-JS-008 negative fixture: dynamic value routed through escapeHtml()
// before reaching innerHTML.

function escapeHtml(value) {
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

export async function showMessage(target) {
    const r = await fetch('/api/notice');
    const data = await r.json();
    target.innerHTML = `<div class="notice">${escapeHtml(data.text)}</div>`;
}
