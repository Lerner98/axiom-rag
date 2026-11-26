import type { Message } from '@/stores/chatStore';

export type AnswerCheckState = 'checking' | 'grounded' | 'ungrounded' | 'not_found';

/** Which check line (if any) belongs under an assistant message. */
export function answerCheckState(message: Message): AnswerCheckState | null {
  if (message.role !== 'assistant') return null;
  if (message.isStreaming) return message.isVerifying ? 'checking' : null;
  if (!message.wasChecked) return null; // no check ran (greeting, nothing retrieved)
  if (message.notFound) return 'not_found'; // a correct "not in your documents" answer
  return message.wasGrounded === false ? 'ungrounded' : 'grounded';
}
