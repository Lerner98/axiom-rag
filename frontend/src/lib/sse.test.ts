import { afterEach, describe, expect, it, vi } from 'vitest';
import { streamChat } from './sse';

function sseResponse(events: object[]): Response {
  const body = events.map((e) => `data: ${JSON.stringify(e)}\r\n\r\n`).join('');
  return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

afterEach(() => vi.unstubAllGlobals());

describe('streamChat status event', () => {
  it('reports the verifying step after the tokens and passes was_checked to onDone', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        sseResponse([
          { type: 'token', content: 'Twenty days.' },
          { type: 'status', step: 'verifying' },
          { type: 'done', message_id: 'm1', was_grounded: false, was_checked: true, processing_time_ms: 900 },
        ]),
      ),
    );
    const order: string[] = [];
    const onDone = vi.fn(() => order.push('done'));
    await streamChat('q', 's1', 'c1', {
      onToken: () => order.push('token'),
      onStatus: (step) => order.push(`status:${step}`),
      onDone,
    });
    expect(order).toEqual(['token', 'status:verifying', 'done']);
    expect(onDone).toHaveBeenCalledWith('m1', false, 900, true);
  });

  it('treats a done event without was_checked as unchecked', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([{ type: 'done', message_id: 'm2', was_grounded: true }])));
    const onDone = vi.fn();
    await streamChat('hi', 's1', 'c1', { onDone });
    expect(onDone).toHaveBeenCalledWith('m2', true, 0, false);
  });
});
