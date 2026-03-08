# JWT Storage for B2B SaaS: Security Tradeoff Analysis

Alex, you've identified the core tension correctly: localStorage is XSS-vulnerable, httpOnly cookies introduce CSRF surface, and your service worker needs JS-accessible tokens. This is a genuine security architecture tradeoff with no single "correct" answer -- it depends on your threat model, your app's specific constraints, and how much complexity you're willing to absorb.

## The Short Answer

The most defensible pattern for SOC2 is a **split-token (BFF) architecture**: short-lived access tokens in memory (not localStorage), refresh tokens in httpOnly secure cookies, and a backend-for-frontend that mediates token exchange for the service worker.

## Why localStorage Is Actually the Problem

The XSS risk isn't theoretical. If an attacker gets JS execution in your app (via a compromised npm dependency, a stored XSS in user-generated content, a malicious browser extension), they can exfiltrate every token in localStorage silently. The token doesn't expire when the tab closes. It can be replayed from anywhere. For SOC2, auditors will flag this as a control gap because you have no mechanism to limit blast radius.

## Why "Just Use httpOnly Cookies" Is Also Not the Answer

You're right that httpOnly cookies don't magically solve things. They introduce:

- **CSRF surface**: Cookies are sent automatically with same-origin requests. You need SameSite=Strict or Lax plus CSRF tokens.
- **Service worker inaccessibility**: httpOnly cookies are invisible to JS, including service workers. Your service worker can't attach them to outbound API calls to third-party services or inspect token claims for routing decisions.
- **Cookie size limits**: JWTs can exceed the 4KB cookie limit, especially with rich claims.

## The Defensible Architecture

Here's what actually works for your constraints:

### 1. Backend-for-Frontend (BFF) Token Mediation

- Your SPA never directly holds long-lived tokens.
- A lightweight BFF (can be a Cloudflare Worker, a small Express service, or an edge function) handles OAuth flows and stores refresh tokens in httpOnly, Secure, SameSite=Strict cookies.
- The BFF issues short-lived (5-15 minute) access tokens to the SPA on demand.

### 2. In-Memory Token Storage in the SPA

- Access tokens live in a JS variable (closure or module-scoped), NOT in localStorage or sessionStorage.
- They survive page navigation via the service worker or a silent token refresh on page load.
- They do NOT survive a full page close -- which is actually a security feature.

### 3. Service Worker Token Access

- The service worker receives the access token via `postMessage` from the main thread after each silent refresh.
- The service worker caches the token in its own scope (not in IndexedDB or Cache API -- just a variable).
- On service worker restart, the main thread re-posts the current token.
- For offline scenarios, the service worker can request a fresh token from the BFF endpoint directly (cookies are sent with fetch from service workers for same-origin requests).

### 4. Defense in Depth

- **Content Security Policy**: Strict CSP with no `unsafe-inline`, no `unsafe-eval`. This is your primary XSS mitigation and auditors will look for it.
- **Subresource Integrity (SRI)**: Pin hashes on third-party scripts.
- **Token binding**: If you can, bind tokens to a device fingerprint or a proof-of-possession key (DPoP). This prevents token exfiltration from being useful even if XSS occurs.
- **Short token lifetimes**: 5-15 minute access tokens mean the window of exploitation is small.

## What to Tell the SOC2 Auditor

The auditor wants to see that you have **compensating controls**. The narrative is:

1. We don't store long-lived credentials in browser-accessible storage.
2. Access tokens are short-lived and held only in memory.
3. Refresh tokens are in httpOnly cookies with SameSite=Strict.
4. We have strict CSP, SRI, and input sanitization as XSS prevention layers.
5. Token revocation is available server-side for incident response.

This is a well-understood, defensible position that aligns with OWASP recommendations.

## Migration Path

If you need to ship this before March:

1. **Week 1**: Add the BFF token endpoint. Move refresh tokens to httpOnly cookies. Keep localStorage as a fallback during migration.
2. **Week 2**: Switch the SPA to in-memory token storage. Update the service worker to receive tokens via postMessage.
3. **Week 3**: Remove localStorage token storage entirely. Deploy strict CSP headers.
4. **Week 4**: Audit, pen-test the new flow, document the control narrative for SOC2.

---

## Council Recommendation

This is exactly the kind of security architecture decision where getting diverse perspectives could be valuable. Different models may weight the CSRF vs. XSS tradeoffs differently or suggest alternative patterns (like Token Binding or using Web Crypto for proof-of-possession). Consider running:

`/claude-council:ask "We need to move JWT storage out of localStorage for SOC2 compliance in a B2B SaaS app. The service worker needs JS-accessible tokens. What's the most defensible split-token or BFF architecture, and are there alternatives we should consider like DPoP or TokenBinding?"`

This will gather opinions from Gemini, OpenAI, Grok, and Perplexity to compare approaches and may surface patterns or risks that a single perspective might miss -- particularly around the service worker token handoff, which is the trickiest part of this architecture.
