import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

test('stdio initialization advertises start/poll/cancel and rejects stale sessions', async t => {
  const client = new Client({ name: 'macshot-protocol-test', version: '1.0.0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('./mcp-server.mjs', import.meta.url))] });
  t.after(() => client.close());
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(t => t.name).sort(), ['macshot_annotate_cancel', 'macshot_annotate_poll', 'macshot_annotate_start']);
  const result = await client.callTool({ name: 'macshot_annotate_poll', arguments: { session: '00000000-0000-4000-8000-000000000000' } });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /expire on restart/);
});
