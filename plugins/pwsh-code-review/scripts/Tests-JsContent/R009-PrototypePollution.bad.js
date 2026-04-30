// PWSH-JS-009 positive fixture: Object.assign spreads an untrusted fetch
// payload directly into a config target. A response that includes
// __proto__ or constructor.prototype mutates the prototype chain.

export async function loadOptions(target) {
    const r = await fetch('/api/options');
    const incoming = await r.json();
    Object.assign(target, incoming);
    return target;
}
