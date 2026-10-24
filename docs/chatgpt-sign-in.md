# Legacy ChatGPT helper (historical)

The app now uses one ChatGPT connection backed by the embedded Codex runtime.
The Node helper described below is no longer launched or packaged. Its existing
credential files remain untouched. See [the current runtime integration](codex-runtime.md).

# Original ChatGPT plan provider

The native Connection Settings panel supports ChatGPT browser sign-in, separate
plan-usage authorization, saved profiles, model discovery, reconnect, usage
management, sign-out, and cancellation. Ollama/API-key settings remain stored
separately from the selected ChatGPT model in the existing settings record.
Older settings files decode as the API provider.

## Runtime

SwiftUI → `ChatGPTAccount` → `ChatGPTHelper` actor → bundled Node process →
OpenAI `@siwc/local` SDK → public Responses API.

The helper uses newline-delimited JSON over anonymous stdin/stdout pipes. Commands
have request IDs; cancellation addresses one request. Account changes are excluded
while inference is active. Display state, model listings, partial output, completed
output, and fixed error messages cross the bridge. Tokens and provider error bodies
do not. The temporary OAuth callback listener binds to IPv4 loopback; there is no
permanent local API server. The parent supplies a minimal environment without API
credentials, OpenAI debug flags, or Node injection options.

The SDK validates PKCE, OAuth state, nonce and signed identity, preserves client
registrations, rotates tokens, and requires `response.completed` for success.
Requests use `https://api.openai.com/v1/responses`, `store: false`, `stream: true`,
and the full user/assistant history. Interrupted, failed, or cancelled responses
are discarded; the original draft returns for editing. Token usage remains
unavailable because the current SDK returns text only; it is never estimated.

## Credential storage

The SDK stores an encrypted credential envelope under
`~/Library/Application Support/VaydeAOS/ChatGPT`, with private directory/file
permissions. A separate signed Swift utility implements AES-256-GCM through
CryptoKit. Its random encryption key resides in the macOS login Keychain under
service `dev.vaydeaos.chatgpt.vault`, account `aes256gcm-v1`. Input and output travel
through anonymous pipes. Decryption never creates a replacement key if the original
is missing. Keychain failures stop credential persistence; there is no plaintext
fallback. Credential-file failures preserve the existing file.

Signing out removes the selected profile's local tokens and attempts remote
revocation. If remote revocation fails, the UI directs the user to disconnect the
app in ChatGPT settings. The SDK retains registration and verified identity for
reconnection, with each saved connection kept separate.

Local ad-hoc signing can require login Keychain approval after rebuilding the
credential utility. This build does not claim Developer ID distribution or
notarization. Account authorization and plan eligibility must be verified in the
user's browser; offline tests do not establish account access.

## Packaging and dependency provenance

`scripts/prepare-chatgpt-helper.sh` downloads Node **v22.23.4** for the host's
arm64/x86_64 architecture, checks its pinned SHA-256, installs `package-lock.json`
dependencies without install scripts, bundles JavaScript, compiles the credential
utility for macOS 13, and signs both executables before signing the outer app.
The official runtime uses system libraries and requires no Homebrew installation.
The app includes DevKit, dependency, and Node license notices.

The SDK's source and upstream tests are vendored unchanged at commit
`0a36fefeb913055c8c7a1a29b63d82b96b2e841a`; see
`Helpers/ChatGPT/vendor/siwc-local/PROVENANCE.md` and `LICENSE`.
OpenAI's DevKit license permits noncommercial use and requires separate rights
for commercial use. Access for paid or remotely hosted applications is separate
from this local personal-project implementation.

## Validation

```sh
./test.sh
./build.sh
cd Helpers/ChatGPT
npm test
cd ../..
python3 scripts/check-chatgpt-helper.py
codesign --verify --deep --strict build/VaydeAOS.app
git diff --check
```

Swift coverage includes legacy settings, provider isolation from API credentials,
complete history, partial-output recovery, cancellation, malformed bridge frames,
helper crashes/restart, and missing runtime errors. Helper tests cover payload
allowlists, display-data isolation, account-change exclusion, identity-only
consent, revocation failures, streaming and targeted cancellation. The unchanged
upstream tests cover identity verification, refresh rotation, encrypted storage,
permissions, provider failures, Responses headers/completion, and interrupted SSE.
The packaged smoke check uses disposable storage and never reads the user's account.

Live validation still requires browser consent, a completed eligible inference,
account-token persistence across app restart, refresh, account switching, sign-out,
and revoked/limited-account behavior. Intel packaging is covered by the CI matrix;
native visual and account behavior on Intel require a device check.

Local validation on Apple Silicon passed native settings inspection, offline
packaged-helper startup/shutdown, ad-hoc signature verification, and a synthetic
cross-process round trip through the real login Keychain encryption utility.
Tampered ciphertext was rejected without returning plaintext. This synthetic
check does not establish access to a ChatGPT account.

## Official references

- [Integration walkthrough](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)
- [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
