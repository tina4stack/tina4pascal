# SSO with RBAC

Generic OpenID Connect / OAuth 2.0 login (Authorization Code + PKCE) with
role- and permission-based access control, built the Tina4 way: portable core
logic, thin OS glue in the shells, and access control expressed declaratively
in HTML.

## Units

| Unit | Role | Status |
|---|---|---|
| `Tina4Crypto` | SHA-256, base64url, PKCE (S256) | ✅ done, tested (NIST + RFC 7636) |
| `Tina4Auth` | OIDC discovery, PKCE authorize URL, token/JWT parse, roles+perms RBAC, claims, expiry, logout, token-request bodies | ✅ done, tested |
| `Tina4AuthFlow` | desktop transport: free port, open browser, **loopback accept**, redirect parse, **session persistence** | ✅ done, tested |
| `Tina4Secrets` | secure token store — DPAPI on Windows, per-user file fallback elsewhere | ✅ Windows done+tested; native keychains = on-device |
| RBAC engine guard | `data-role` / `data-perm` hide elements the user can't access | ✅ done, tested |

## The desktop login flow

A desktop shell composes the provided helpers — every piece below ships and is
tested (only the live browser + the IdP round-trip are external):

```pascal
uses Tina4Auth, Tina4AuthFlow, Tina4Http;

var cfg: TTina4AuthConfig; port: Word;
    url, verifier, state, code, gotState, err: string;

port := TinaAuthFreePort(8760, 8790);                 // pick a loopback port
FillChar(cfg, SizeOf(cfg), 0);
cfg.ClientId    := 'my-client';
cfg.AuthEndpoint  := 'https://idp.example/authorize'; // or TinaAuthDiscover(...)
cfg.TokenEndpoint := 'https://idp.example/token';
cfg.RedirectUri := 'http://127.0.0.1:' + IntToStr(port) + '/cb';
cfg.RolesClaim  := 'roles';       // Keycloak: 'realm_access.roles'
cfg.PermsClaim  := 'permissions';
TinaAuthConfigure(cfg);

url := TinaAuthAuthorizeUrl(verifier, state);         // PKCE challenge + state
TinaAuthOpenBrowser(url);                             // system browser (user logs in)

if TinaAuthAwaitRedirect(port, 120000, code, gotState, err) then   // 2-min wait, no hang
  if (err = '') and (gotState = state) then           // verify state (CSRF)
    HttpPost(TinaAuthTokenEndpoint,                    // exchange code → tokens
             TinaAuthTokenBody(code, verifier),
             'application/x-www-form-urlencoded',
             procedure(const R: TTina4HttpResponse)
             begin
               if (R.Status = 200) and TinaAuthHandleTokenResponse(R.Body) then
                 TinaAuthSaveSession('tina4.session'); // persist (encrypted on Windows)
             end);
```

On next launch, `TinaAuthRestoreSession('tina4.session')` brings the user back
signed in, re-deriving roles/claims/expiry from the stored JWT. `TinaAuthLogout`
+ `TinaAuthClearSession` sign out.

Mobile uses a custom URI scheme (`myapp://cb`) instead of the loopback; the
shell hands the redirect's query to `AuthParseRedirect` the same way.

## RBAC in HTML

Install the guard once (`TinaAuthInstallGuard`); then any element carrying
`data-role` or `data-perm` is hidden unless the signed-in user qualifies:

```html
<a href="#" data-perm="invoice.write">New invoice</a>
<section data-role="admin"> … admin panel … </section>
```

In Pascal: `TinaHasRole('admin')`, `TinaCan('invoice.write')`, `TinaClaim('email')`.

## What's finished vs. on-device

**Done + tested here** (Windows native + Linux via WSL): the crypto, the OIDC/
PKCE/JWT/RBAC brain, the declarative guard, the loopback accept (real socket,
with a timeout that can't hang), redirect parsing, session persistence, and
Windows DPAPI at-rest encryption.

**On-device finish** (per-shell, device-bound — same boundary as the barcode
camera): the native keychains beyond Windows (macOS Keychain, Linux libsecret,
Android Keystore, iOS Keychain) behind `Tina4Secrets`; the live HTTP token
exchange against a real IdP (needs a shell HTTP backend); and the mobile
custom-scheme redirect capture.
