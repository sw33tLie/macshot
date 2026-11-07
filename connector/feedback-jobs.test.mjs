import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, rm, writeFile, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { FeedbackJobs } from './feedback-jobs.mjs';

async function fixture(t) {
  const directory = await realpath(await mkdtemp(path.join(tmpdir(), 'macshot-mcp-')));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = signal => { child.signal = signal; };
  const registry = new FeedbackJobs({ cli: '/app/macshot-cli', handoff: '/private/handoff', spawnCLI: (exe, args, options) => {
    child.exe = exe; child.args = args; child.options = options; return child;
  } });
  const result = await registry.start({ image: '/input/a; b.png', output: directory });
  return { directory, child, registry, id: result.session };
}

test('start returns immediately and passes paths as arguments without shell interpretation', async t => {
  const { registry, child, id } = await fixture(t);
  assert.equal((await registry.poll(id)).structuredContent.state, 'waiting');
  assert.equal(child.args[1], '/input/a; b.png');
  assert.equal(child.options.shell, false);
});

test('cancel is idempotent and waits for the actual terminal result', async t => {
  const { registry, child, id } = await fixture(t);
  assert.equal(registry.cancel(id).state, 'cancelling');
  registry.cancel(id);
  assert.equal(child.signal, 'SIGTERM');
  child.emit('close', 4);
  assert.equal((await registry.poll(id)).structuredContent.state, 'cancelled');
});

test('a submission winning a cancellation race stays submitted with matching attachments', async t => {
  const { registry, child, id, directory } = await fixture(t);
  await writeFile(path.join(directory, 'feedback.json'), JSON.stringify({ format: 'macshot-feedback-1', notes: [{ comment: '改成蓝色' }] }));
  await writeFile(path.join(directory, 'feedback.md'), '修改 1\n改成蓝色');
  for (const name of ['source.png', 'preview.png']) await writeFile(path.join(directory, name), Buffer.from('png fixture'));
  registry.cancel(id);
  child.stdout.write(JSON.stringify({ state: 'submitted', feedback: path.join(directory, 'feedback.json') }));
  child.emit('close', 0);
  const result = await registry.poll(id);
  assert.equal(result.structuredContent.state, 'submitted');
  assert.equal(result.structuredContent.noteCount, 1);
  assert.equal(result.content.filter(c => c.type === 'image').length, 2);
  assert.ok(result.content.some(c => c.type === 'text' && c.text.includes('改成蓝色')));
});

test('mismatched CLI receipts are rejected rather than returning a different round', async t => {
  const { registry, child, id } = await fixture(t);
  child.stdout.write(JSON.stringify({ state: 'submitted', feedback: '/another/feedback.json' }));
  child.emit('close', 0);
  await assert.rejects(registry.poll(id), /does not match/);
});

test('spawn errors and restarted connector IDs are explicit failures', async t => {
  const { registry, child, id } = await fixture(t);
  child.emit('error', new Error('CLI missing'));
  assert.equal((await registry.poll(id)).structuredContent.state, 'failed');
  assert.throws(() => registry.cancel('old-session'), /expire on restart/);
});
