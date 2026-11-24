/**
 * Server-Sent Events client for streaming chat answers (V6 TRUE STREAMING).
 *
 * The backend (sse-starlette) sends one JSON object per `data:` line:
 *   {type:'phase', phase}  {type:'sources', sources}  {type:'token', content}
 *   {type:'done', message_id, was_grounded, processing_time_ms}
 *   {type:'error', message, code}
 * EventSource can't POST, so this reads the response body with fetch.
 */

import { API_CONFIG, API_ENDPOINTS, ERROR_CODES } from '@/constants/api';
import type { Source, SSEStreamingPhase, StreamEvent } from '@/types';

export interface StreamCallbacks {
  onPhase?: (phase: SSEStreamingPhase) => void;
  onToken?: (token: string) => void;
  onSources?: (sources: Source[]) => void;
  onDone?: (messageId: string, wasGrounded: boolean, processingTimeMs: number) => void;
  onError?: (error: Error) => void;
}

/**
 * Stream an answer for `message`.
 * @param sessionId conversation memory key (the chat id, so chats stay isolated)
 * @param chatId    chat-scoped collection (ADR-007); omit to use the global endpoint
 */
export async function streamChat(
  message: string,
  sessionId: string,
  chatId: string | undefined,
  callbacks: StreamCallbacks,
  signal?: AbortSignal,
): Promise<void> {
  const path = chatId ? API_ENDPOINTS.chatStreamScoped(chatId) : API_ENDPOINTS.chatStream;

  let res: Response;
  try {
    res = await fetch(`${API_CONFIG.baseUrl}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'text/event-stream' },
      body: JSON.stringify({ message, session_id: sessionId }),
      signal,
    });
  } catch {
    callbacks.onError?.(new Error('Cannot reach the Axiom backend. Is it running on ' + API_CONFIG.baseUrl + '?'));
    return;
  }

  if (!res.ok || !res.body) {
    let detail = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      detail = body.detail || detail;
    } catch {
      /* ignore */
    }
    callbacks.onError?.(new Error(typeof detail === 'string' ? detail : JSON.stringify(detail)));
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let finished = false;

  const handle = (evt: StreamEvent) => {
    switch (evt.type) {
      case 'phase':
        if (evt.phase) callbacks.onPhase?.(evt.phase);
        break;
      case 'sources':
        callbacks.onSources?.((evt.sources ?? []) as Source[]);
        break;
      case 'token':
        if (evt.content) callbacks.onToken?.(evt.content);
        break;
      case 'done':
        finished = true;
        callbacks.onDone?.(evt.message_id ?? '', evt.was_grounded ?? true, evt.processing_time_ms ?? 0);
        break;
      case 'error':
        finished = true;
        callbacks.onError?.(Object.assign(new Error(evt.message || 'Streaming failed'), {
          code: evt.code || ERROR_CODES.STREAM_ERROR,
        }));
        break;
    }
  };

  const processLine = (rawLine: string) => {
    const line = rawLine.replace(/\r$/, '');
    if (!line.startsWith('data:')) return; // ignore comments, ping, event:, id:
    const payload = line.slice(5).trimStart();
    if (!payload) return;
    try {
      handle(JSON.parse(payload) as StreamEvent);
    } catch {
      /* partial or non-JSON line; skip */
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let nl: number;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      processLine(buffer.slice(0, nl));
      buffer = buffer.slice(nl + 1);
    }
  }
  buffer += decoder.decode();
  if (buffer) processLine(buffer);

  if (!finished) {
    callbacks.onError?.(new Error('The connection closed before the answer finished.'));
  }
}
