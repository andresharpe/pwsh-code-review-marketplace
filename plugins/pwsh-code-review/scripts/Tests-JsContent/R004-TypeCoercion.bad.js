// PWSH-JS-004 positive fixture: == compare and bare-falsy on a value
// that can legitimately be 0.

export function shouldRetry(attemptCount) {
    if (attemptCount == null) {
        return true;
    }
    if (!attemptCount) {
        // Wrong: when attemptCount === 0 (no attempts yet), this returns true,
        // but the intent is "retry only when prior attempts failed".
        return true;
    }
    return attemptCount < 3;
}
