// PWSH-JS-002 positive fixture: listener accumulates across renders.
// `render` runs every time the route changes; addEventListener fires every
// time without removal, so handlers stack up.

export function render(container) {
    const button = container.querySelector('.refresh');
    button.addEventListener('click', () => {
        fetch('/api/data');
    });
}
