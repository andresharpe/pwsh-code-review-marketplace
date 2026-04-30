// PWSH-JS-002 negative fixture: AbortController scoped to the render so
// every listener is torn down before the next render attaches its own.

export function render(container) {
    const ac = new AbortController();
    const button = container.querySelector('.refresh');
    button.addEventListener('click', () => {
        fetch('/api/data');
    }, { signal: ac.signal });

    return () => ac.abort();
}
