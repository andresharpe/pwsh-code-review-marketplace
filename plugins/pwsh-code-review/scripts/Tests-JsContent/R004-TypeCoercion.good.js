// PWSH-JS-004 negative fixture: strict equality + explicit branch for 0.

export function shouldRetry(attemptCount) {
    if (attemptCount === null || attemptCount === undefined) {
        return true;
    }
    if (attemptCount === 0) {
        return false;
    }
    return attemptCount < 3;
}
