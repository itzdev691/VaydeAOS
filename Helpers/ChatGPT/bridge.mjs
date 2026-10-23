import { ChatGPTError } from './vendor/siwc-local/dist/index.js';

// Expose only SDK display types, never arbitrary objects or provider messages.
export function safeError(error) {
  const code = error instanceof ChatGPTError ? error.code : 'helper_error';
  const messages = {
    cancelled: 'The operation was cancelled.',
    sign_in_required: 'Sign in with ChatGPT to continue.',
    sharing_not_enabled: 'Authorize ChatGPT plan usage to continue.',
    access_denied: 'ChatGPT sign-in was declined.',
    connection_busy: 'Finish the current account operation first.',
    network_error: 'Could not reach ChatGPT. Check your connection.',
    connection_error: 'Could not complete the ChatGPT connection. Check your network and retry.',
    model_not_found: 'This model is unavailable. Refresh the model list.',
    invalid_client: 'OpenAI rejected this app registration. Reconnect the saved account.',
    revocation_failed: 'Local credentials were removed. Remote sign-out could not be confirmed; disconnect VaydeAOS in ChatGPT settings.',
    credential_storage_unavailable: 'macOS credential encryption is unavailable. Check login Keychain access.',
    subscription_sharing_user_not_eligible: 'This account or workspace is not eligible for ChatGPT plan usage.',
    subscription_sharing_usage_limit_exceeded: 'ChatGPT plan usage limit reached. Open Manage usage.',
    subscription_sharing_v2_client_not_enabled: 'OpenAI has not enabled ChatGPT plan usage for this app registration.',
    stream_interrupted: 'The response ended before completion. Send the message again.',
    response_incomplete: 'ChatGPT stopped before completing the response. Send the message again.',
    refresh_token_expired: 'Your ChatGPT session expired. Reconnect the saved account.',
    invalid_refresh_token: 'Your ChatGPT session can no longer be renewed. Reconnect the saved account.',
    token_expired: 'Your ChatGPT session expired. Reconnect the saved account.',
    refresh_token_invalidated: 'Your ChatGPT session was revoked. Reconnect the saved account.',
    refresh_not_ready: 'Your ChatGPT session cannot refresh yet. Retry shortly.',
    refresh_token_reused: 'Your ChatGPT session needs a new sign-in.',
    invalid_grant: 'Your ChatGPT authorization expired. Reconnect the saved account.',
    invalid_request: 'The request format is invalid.',
    storage_error: 'The protected ChatGPT connection could not be read or saved. Check login Keychain access.',
    storage_unavailable: 'Protected ChatGPT storage is unavailable. Check login Keychain access.',
    storage_encryption_unavailable: 'Credential encryption is unavailable. Unlock the login Keychain and reconnect.',
    storage_decryption_failed: 'Saved credentials could not be decrypted. Restore login Keychain access. The saved file was preserved.',
    storage_encryption_failed: 'Credentials could not be encrypted. Check login Keychain access. The saved file was preserved.',
    storage_encrypted_invalid: 'The saved credential file is damaged or unsupported. The file was preserved.',
    storage_invalid: 'The saved ChatGPT connection is unreadable. The file was preserved.',
    storage_unsafe: 'ChatGPT storage must be a private directory owned by this macOS account.',
    storage_busy: 'Another VaydeAOS process is updating the connection. Close that copy and retry.',
    storage_provider_mismatch: 'This credential file uses a different encryption provider. The file was preserved.',
  };
  if (Object.hasOwn(messages, code)) return { code, message: messages[code] };
  const status = error instanceof ChatGPTError ? error.status : undefined;
  if (status === 401) return { code: 'authorization_rejected', message: 'ChatGPT rejected this connection. Reconnect and check plan-usage permission.' };
  if (status === 403) return { code: 'access_restricted', message: 'An account, workspace, or regional restriction prevented this ChatGPT request.' };
  if (status === 429) return { code: 'rate_limited', message: 'ChatGPT requests are temporarily limited. Wait and retry, or review Manage usage.' };
  if (status >= 500) return { code: 'service_unavailable', message: 'ChatGPT is temporarily unavailable. Retry shortly.' };
  return { code: 'chatgpt_error', message: 'The ChatGPT operation failed. Check the connection and reconnect if needed.' };
}

export function safeSession(state) {
  return { status: state.status, sharing: state.sharing === true,
    profileId: state.profileId, profileLabel: state.profileLabel,
    identity: state.identity ? { name: state.identity.name, email: state.identity.email } : undefined,
    error: state.error ? safeError(new ChatGPTError(state.error.code, '', false, state.error.status)) : undefined };
}

export function safeProfiles(profiles) {
  return profiles.map(p => ({ id: p.id, label: p.label, status: p.status, sharing: p.sharing === true,
    pending: p.pending === true, requiresNewRegistration: p.requiresNewRegistration === true,
    identity: p.identity ? { name: p.identity.name, email: p.identity.email } : undefined }));
}

export function createBridge(chatgpt, send) {
  const active = new Map();
  let changingAccount = false;
  async function state() {
    const session = safeSession(await chatgpt.getSession());
    try { return { session, profiles: safeProfiles(await chatgpt.listProfiles()) }; }
    catch (error) { return { session, profiles: [], error: safeError(error) }; }
  }
  async function dispatch(request) {
    const { id, method } = request;
    if (typeof id !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(id)) return;
    if (method === 'cancel') {
      active.get(request.target)?.abort();
      return;
    }
    if (active.has(id)) return;
    const controller = new AbortController();
    active.set(id, controller);
    const accountChange = ['signIn', 'selectProfile', 'disconnect'].includes(method);
    let ownsAccountChange = false;
    try {
      if (changingAccount || (accountChange && active.size > 1)) throw new ChatGPTError('connection_busy', '');
      if (accountChange) { changingAccount = true; ownsAccountChange = true; }
      let result;
      switch (method) {
        case 'state': result = await state(); break;
        case 'signIn':
          await chatgpt.signIn({ signal: controller.signal, newProfile: request.newProfile === true,
            profileId: request.profileId, reconsent: request.reconsent === true });
          result = await state(); break;
        case 'selectProfile':
          if (typeof request.profileId !== 'string') throw new ChatGPTError('invalid_request', '');
          await chatgpt.selectProfile(request.profileId); result = await state(); break;
        case 'disconnect': await chatgpt.disconnect(); result = await state(); break;
        case 'models': result = { models: await chatgpt.listModels({ signal: controller.signal }) }; break;
        case 'reply': {
          if (typeof request.model !== 'string' || !Array.isArray(request.messages) || !request.messages.length ||
              request.messages.some(m => !m || !['user', 'assistant'].includes(m.role) || typeof m.content !== 'string')) {
            throw new ChatGPTError('invalid_request', '');
          }
          const reply = await chatgpt.streamResponse({ model: request.model,
            input: request.messages.map(m => ({ role: m.role, content: m.content })), signal: controller.signal,
            onDelta: delta => { if (!controller.signal.aborted) send({ id, kind: 'delta', delta }); } });
          controller.signal.throwIfAborted();
          result = { text: reply.text }; break;
        }
        default: throw new ChatGPTError('invalid_request', '');
      }
      send({ id, kind: 'result', ...result });
    } catch (error) {
      const failure = controller.signal.aborted ? new ChatGPTError('cancelled', '') : error;
      // Refresh display state after failures such as revoked credentials or incomplete sign-out.
      let snapshot;
      if (ownsAccountChange || method === 'reply' || method === 'models') {
        try { snapshot = await state(); } catch { /* Preserve the original safe error. */ }
      }
      send({ id, kind: 'result', ...snapshot, error: safeError(failure) });
    } finally {
      active.delete(id);
      if (ownsAccountChange) changingAccount = false;
    }
  }
  return { dispatch, close() { chatgpt.cancelSignIn(); for (const controller of active.values()) controller.abort(); } };
}
