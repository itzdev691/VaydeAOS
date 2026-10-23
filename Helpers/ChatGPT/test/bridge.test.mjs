import assert from 'node:assert/strict';
import test from 'node:test';
import { createBridge, safeError, safeProfiles, safeSession } from '../bridge.mjs';
import { ChatGPTError } from '../vendor/siwc-local/dist/index.js';

function fixture(overrides = {}) {
  const output = [];
  const client = {
    getSession: async () => ({ status: 'connected', sharing: true, profileId: 'profile', credentials: 'secret' }),
    listProfiles: async () => [{ id: 'profile', label: 'Account', status: 'connected', sharing: true, refreshToken: 'secret' }],
    cancelSignIn() {},
    ...overrides,
  };
  return { output, client, bridge: createBridge(client, value => output.push(value)) };
}

test('display snapshots exclude credentials, grants and arbitrary SDK fields', async () => {
  const { bridge, output } = fixture();
  await bridge.dispatch({ id: '1', method: 'state' });
  const wire = JSON.stringify(output);
  assert.ok(!wire.includes('secret'));
  assert.ok(!wire.includes('credentials'));
  assert.ok(!wire.includes('refreshToken'));
  assert.equal(output[0].session.profileId, 'profile');
});

test('reply sends full text history and only approved fields; streams and waits for completion', async () => {
  let finish;
  const { bridge, output } = fixture({ streamResponse: async options => {
    assert.equal(options.model, 'test-model');
    assert.deepEqual(options.input, [{ role: 'user', content: 'Prompt' }, { role: 'assistant', content: 'Answer' }, { role: 'user', content: 'Follow-up' }]);
    assert.equal(options.signal.aborted, false);
    options.onDelta('Part');
    await new Promise(resolve => { finish = resolve; });
    options.onDelta(' two');
    return { text: 'Part two', credentials: 'secret' };
  } });
  const running = bridge.dispatch({ id: 'reply', method: 'reply', model: 'test-model',
    messages: [{ role: 'user', content: 'Prompt', token: 'secret' }, { role: 'assistant', content: 'Answer' }, { role: 'user', content: 'Follow-up' }] });
  assert.equal(output.length, 1);
  assert.equal(output[0].kind, 'delta');
  finish(); await running;
  assert.equal(output.at(-1).text, 'Part two');
  assert.ok(!JSON.stringify(output).includes('secret'));
});

test('cancellation aborts only its target and never returns a late successful result', async () => {
  let finish;
  const { bridge, output } = fixture({ streamResponse: async options => {
    await new Promise(resolve => { finish = resolve; });
    options.onDelta('late');
    return { text: 'late' };
  } });
  const running = bridge.dispatch({ id: 'reply', method: 'reply', model: 'test', messages: [{ role: 'user', content: 'Test' }] });
  await bridge.dispatch({ id: 'cancel', method: 'cancel', target: 'reply' });
  finish(); await running;
  assert.equal(output.length, 1);
  assert.equal(output[0].error.code, 'cancelled');
  assert.equal(output[0].text, undefined);
});

test('account switching cannot race with an active inference', async () => {
  let finish;
  const { bridge, output } = fixture({ streamResponse: async () => { await new Promise(r => { finish = r; }); return { text: 'done' }; } });
  const running = bridge.dispatch({ id: 'reply', method: 'reply', model: 'test', messages: [{ role: 'user', content: 'Test' }] });
  await bridge.dispatch({ id: 'switch', method: 'selectProfile', profileId: 'other' });
  assert.equal(output.at(-1).error.code, 'connection_busy');
  finish(); await running;
});

test('identity-only sign-in remains connected with plan use disabled', async () => {
  const { bridge, output } = fixture({ signIn: async options => { assert.equal(options.reconsent, false); },
    getSession: async () => ({ status: 'connected', sharing: false }) });
  await bridge.dispatch({ id: 'login', method: 'signIn' });
  assert.equal(output.at(-1).session.status, 'connected');
  assert.equal(output.at(-1).session.sharing, false);
});

test('revocation failure preserves disconnected state and gives the usage recovery action', async () => {
  const { bridge, output } = fixture({ disconnect: async () => { throw new ChatGPTError('revocation_failed', 'secret provider message'); },
    getSession: async () => ({ status: 'disconnected', sharing: false }) });
  await bridge.dispatch({ id: 'logout', method: 'disconnect' });
  assert.equal(output.at(-1).session.status, 'disconnected');
  assert.equal(output.at(-1).error.code, 'revocation_failed');
  assert.ok(!JSON.stringify(output).includes('secret'));
});

test('provider errors and malformed roles never expose raw data', async () => {
  assert.ok(!JSON.stringify(safeError(new Error('secret'))).includes('secret'));
  assert.ok(!JSON.stringify(safeError(new ChatGPTError('secret', 'secret'))).includes('secret'));
  const { bridge, output } = fixture();
  await bridge.dispatch({ id: 'invalid', method: 'reply', model: 'test', messages: [{ role: 'system', content: 'secret' }] });
  assert.equal(output.at(-1).error.code, 'invalid_request');
  assert.ok(!JSON.stringify(output).includes('secret'));
});

test('account profiles keep registration identity without propagating hidden metadata', () => {
  assert.deepEqual(safeProfiles([{ id: '1', label: 'One', status: 'disconnected', identity: { email: 'test@example.invalid', token: 'secret' } }])[0].identity,
    { name: undefined, email: 'test@example.invalid' });
  assert.equal(safeSession({ status: 'connected', sharing: false }).sharing, false);
});

test('unreadable credential storage retains the SDK reauthentication state', async () => {
  const { bridge, output } = fixture({
    getSession: async () => ({ status: 'reauth_required', sharing: false,
      error: { code: 'storage_decryption_failed', message: 'secret' } }),
    listProfiles: async () => { throw new ChatGPTError('storage_decryption_failed', 'secret'); },
  });
  await bridge.dispatch({ id: 'state', method: 'state' });
  assert.equal(output[0].session.status, 'reauth_required');
  assert.equal(output[0].session.sharing, false);
  assert.equal(output[0].error.code, 'storage_decryption_failed');
  assert.ok(!JSON.stringify(output).includes('secret'));
});
