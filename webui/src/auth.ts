// Client-side auth helpers. The server's AUTH_TOKEN gates every API route and
// the Web UI. Browsers authenticate once by POSTing the token to
// /zed/auth/login, which sets an HttpOnly `auth` cookie the browser sends
// automatically on subsequent same-origin requests. We additionally mirror the
// token into localStorage so the in-page fetches can attach an explicit
// `x-api-key` header as a fallback (and so API clients can copy it out).

const LS_KEY = 'zed2api_token'

/** Read the token from localStorage (the cookie is HttpOnly, so JS can't see it). */
export function getStoredToken(): string | null {
  try {
    return localStorage.getItem(LS_KEY)
  } catch {
    return null
  }
}

/** Persist the token locally after a successful login. */
export function setStoredToken(token: string): void {
  try {
    if (token) localStorage.setItem(LS_KEY, token)
    else localStorage.removeItem(LS_KEY)
  } catch {
    /* ignore storage failures (private mode, etc.) */
  }
}

export function clearStoredToken(): void {
  try {
    localStorage.removeItem(LS_KEY)
  } catch {
    /* ignore */
  }
}

/**
 * Whether the *client* believes it is logged in. The cookie is HttpOnly so this
 * is a best-effort proxy based on localStorage; the server is the source of
 * truth and will return 401 if the cookie is absent/expired.
 */
export function hasLocalToken(): boolean {
  return !!getStoredToken()
}

/** Headers carrying the shared token, for fetches that need explicit auth. */
export function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const h: Record<string, string> = { ...extra }
  const t = getStoredToken()
  if (t) h['x-api-key'] = t
  return h
}

/** Submit a token to the server; on success it sets the HttpOnly auth cookie. */
export async function loginWithToken(token: string): Promise<boolean> {
  const r = await fetch('/zed/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  })
  if (!r.ok) return false
  setStoredToken(token)
  return true
}
