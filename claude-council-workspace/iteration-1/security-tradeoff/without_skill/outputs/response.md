# JWT Storage for B2B SaaS: The Actual Right Answer

## First, Two Premises to Challenge

**"httpOnly cookies have their own CSRF problems."** This overstates the risk. `SameSite=Strict` (or `Lax`) eliminates the vast majority of CSRF vectors in modern browsers. Pair it with a CSRF token on state-changing endpoints and the residual risk is negligible. The tradeoff between localStorage-XSS and httpOnly-cookie-CSRF is *not* symmetric — XSS token theft gives an attacker persistent, exfiltratable credentials; CSRF requires the victim to be actively browsing your site and limits the attacker to blind requests. localStorage is strictly worse.

**"We need the token accessible from JS for our service worker."** This is likely a false constraint. Service workers on the same origin automatically attach cookies to fetch requests. If your service worker is intercepting API calls for caching or background sync, httpOnly cookies travel with those requests without any JS access to the token. The only scenario where the SW genuinely needs a raw token is when it makes authenticated requests from a context with no cookie jar (e.g., handling a push event). Even then, the answer is a limited-scope token, not your full access JWT.

## The Architecture: In-Memory Access Token + httpOnly Refresh Cookie

This is the standard secure pattern for SPAs that need authorization headers. It is not a novel idea — it is the convergence of OWASP, OAuth 2.0 for Browser-Based Apps (RFC draft), and what major auth providers (Auth0, Okta) now recommend.

### How It Works

1. **Login** — Your auth endpoint authenticates the user and sets two things:
   - An **httpOnly, Secure, SameSite=Strict** cookie containing a refresh token (or opaque session ID)
   - A response body containing a short-lived access token (5-15 minute expiry)

2. **Token storage** — The SPA stores the access token in a **JavaScript variable** (a module-scoped `let`, a Zustand/Redux store, a React context — anything that lives in memory). Not localStorage. Not sessionStorage. Just RAM.

3. **API calls** — The main thread attaches the access token via `Authorization: Bearer <token>` header.

4. **Token refresh** — When the access token expires (or proactively, before it expires), the SPA calls your `/token/refresh` endpoint. The httpOnly refresh cookie travels with this request automatically. The endpoint returns a new short-lived access token. No JS access to the refresh token ever occurs.

5. **Page reload** — On load, the app calls `/token/refresh`. The cookie is still there; a fresh access token is returned. The user experience is seamless.

6. **Service worker** — Two options depending on your SW use case:
   - **For fetch interception (caching, offline, background sync):** Use the httpOnly cookie approach for these requests instead of the Authorization header. The SW makes fetch requests, cookies attach automatically. No token in JS needed.
   - **For push notifications or other SW-initiated calls:** The main thread sends the short-lived access token to the SW via `postMessage`. The SW holds it in memory (not IndexedDB). When the token expires, the main thread refreshes and sends the new one. If the SW wakes from a push event with no token, it calls your `/token/refresh` endpoint (the cookie is available to the SW on same-origin requests).

7. **CSRF protection on the refresh endpoint** — Use the double-submit cookie pattern or a server-generated CSRF token. This is the one endpoint where CSRF matters because it uses cookie auth and changes state (issues a new token).

### Token Lifetimes

| Token | Storage | Lifetime | Rotation |
|-------|---------|----------|----------|
| Refresh token | httpOnly cookie | 24h-7d (your call) | Rotated on each use (detect reuse = revoke family) |
| Access token | JS memory | 5-15 minutes | Silent refresh before expiry |

### Cookie Attributes (Non-Negotiable)

```
Set-Cookie: refresh_token=<value>;
  HttpOnly;
  Secure;
  SameSite=Strict;
  Path=/api/auth;
  Max-Age=604800;
```

- **HttpOnly** — JS cannot read it. XSS cannot exfiltrate it.
- **Secure** — HTTPS only.
- **SameSite=Strict** — Not sent on cross-origin requests. Eliminates most CSRF.
- **Path=/api/auth** — Cookie is only sent to your auth endpoints, not every API call. Reduces attack surface.

## Why This Satisfies SOC2

SOC2 Trust Services Criteria (specifically CC6.1, CC6.6, CC6.7) care about:

| SOC2 Concern | How This Addresses It |
|---|---|
| Credential storage | Refresh token in httpOnly cookie (not accessible to client-side code); access token in volatile memory only |
| Token theft via XSS | Access token is short-lived (minutes); refresh token is inaccessible to JS |
| Token theft via CSRF | SameSite=Strict + CSRF token on refresh endpoint |
| Token rotation | Refresh token rotated on each use with reuse detection |
| Transmission security | Secure flag + HTTPS enforcement |
| Session termination | Revoke refresh token server-side; access token expires naturally in minutes |

An auditor will see: credentials are not persisted in browser-accessible storage, tokens are short-lived and rotated, transport is encrypted, and you have defense-in-depth. This is a defensible, standard architecture.

## What You Must Also Do (Defense in Depth)

Fixing token storage does not excuse you from preventing XSS in the first place. If an attacker achieves XSS, they can make authenticated requests as the user for as long as the user's session is open — even without stealing the token. Token storage hygiene limits the blast radius (no persistent credential theft, no use after the user closes the tab), but it does not eliminate the impact of XSS.

### Content Security Policy (Critical)

Deploy a strict CSP. At minimum:

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  connect-src 'self' https://your-api.example.com;
  frame-ancestors 'none';
```

No `'unsafe-eval'`. No `'unsafe-inline'` for scripts. No wildcard origins. If your build tooling requires inline scripts, use nonce-based CSP (`'nonce-<random>'`). This is the single most effective XSS mitigation and auditors will look for it.

### Additional XSS Hardening

- **Subresource Integrity (SRI)** on all third-party scripts
- **Input sanitization** on the server side (do not trust the client)
- **Output encoding** context-appropriate (HTML, JS, URL, CSS contexts each need different encoding)
- **X-Content-Type-Options: nosniff**
- **Trusted Types** if your browser support matrix allows it (Chrome-only as of early 2026, but covers a large B2B audience)

## The Gold Standard: BFF Pattern

If you want to go further, the Backend-for-Frontend (BFF) proxy pattern eliminates the token from the browser entirely:

- A thin server-side proxy sits between your SPA and your APIs
- The SPA authenticates with the BFF via httpOnly session cookie
- The BFF attaches the access token to upstream API requests server-side
- The browser never sees a JWT at all
- Service worker fetch requests carry the session cookie automatically

This is the architecture recommended by the OAuth 2.0 for Browser-Based Apps draft (Section 6.2) and is the direction the industry is moving. It adds infrastructure complexity (you need to deploy and maintain the proxy), but it completely eliminates the "token in the browser" problem.

**For your SOC2 timeline:** If you are weeks away from the audit, the in-memory pattern described above is the pragmatic move — it is a well-understood, auditor-friendly architecture that you can implement without new infrastructure. Plan the BFF migration as a follow-up.

## Migration Path from localStorage

1. **Add the `/token/refresh` endpoint** that reads the httpOnly cookie and returns a short-lived access token
2. **Update your login flow** to set the httpOnly refresh cookie and return the access token in the response body
3. **Update your SPA's token management** to store the access token in memory and call the refresh endpoint on load and before expiry
4. **Update your service worker** to either rely on cookies (for fetch interception) or receive the token via `postMessage`
5. **Remove all `localStorage.getItem/setItem` calls** for tokens
6. **Deploy CSP headers** if you haven't already
7. **Test thoroughly** — pay attention to page reloads, multi-tab behavior, and token refresh race conditions (use a mutex or queue for refresh calls to avoid multiple concurrent refresh requests)

## Summary

The localStorage vs. httpOnly cookie framing is a false dichotomy. The answer is **both**: httpOnly cookie for the long-lived refresh token, in-memory JavaScript variable for the short-lived access token, and `postMessage` or cookie-based auth for the service worker depending on its role. Pair this with a strict CSP, and you have a defensible architecture for SOC2 and beyond.
