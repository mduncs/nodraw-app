// One reservation per post, shared by every copy of its button in a timeline.
// Reserve before status lookup/prompt/screenshot. Only the owning operation can
// release it; late completion from an earlier attempt cannot unlock a retry.
export function createCaptureAdmission() {
  const reservations = new Map();
  return {
    has(key) { return reservations.has(key); },
    reserve(key) {
      if (reservations.has(key)) return null;
      const token = Symbol(key);
      reservations.set(key, token);
      return {
        release() {
          if (reservations.get(key) === token) reservations.delete(key);
        }
      };
    }
  };
}
