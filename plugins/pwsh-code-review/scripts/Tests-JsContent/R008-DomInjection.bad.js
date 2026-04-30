// PWSH-JS-008 positive fixture: innerHTML interpolates an untrusted
// fetch response value with no escapeHtml() call. Reflected XSS waiting
// to happen.

export async function showMessage(target) {
    const r = await fetch('/api/notice');
    const data = await r.json();
    target.innerHTML = `<div class="notice">${data.text}</div>`;
}
