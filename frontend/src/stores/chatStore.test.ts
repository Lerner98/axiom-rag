import { beforeEach, describe, expect, it } from 'vitest';
import { useChatStore } from './chatStore';

describe('chatStore check result', () => {
  beforeEach(() => {
    useChatStore.getState().resetSession();
    useChatStore.getState().createNewChat();
  });

  it('stores wasChecked and wasGrounded on the finished message and persists them', () => {
    const s = useChatStore.getState();
    s.addUserMessage('How many vacation days?');
    s.startStreaming();
    s.appendStreamToken('Twenty days.');
    s.setStreamingPhase('verifying');
    expect(useChatStore.getState().streamingPhase).toBe('verifying');

    s.finishStreaming(false, 1200, true, false);

    const st = useChatStore.getState();
    const msg = st.chats[0].messages.at(-1)!;
    expect(msg).toMatchObject({ role: 'assistant', wasChecked: true, wasGrounded: false, notFound: false });
    expect(st.streamingPhase).toBe('idle');

    // zustand persist writes the chats to localStorage, so the result survives a reload
    const saved = JSON.parse(localStorage.getItem('rag_chat_store')!);
    expect(saved.state.chats[0].messages.at(-1)).toMatchObject({ wasChecked: true, wasGrounded: false });
  });
});
