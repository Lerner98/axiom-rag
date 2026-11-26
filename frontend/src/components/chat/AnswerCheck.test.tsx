import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MessageBubble } from './MessageBubble';
import { answerCheckState } from './answerCheckState';
import type { Message } from '@/stores/chatStore';

const answer = (extra: Partial<Message> = {}): Message => ({
  id: 'm1',
  role: 'assistant',
  content: 'Employees get 20 vacation days.',
  timestamp: new Date(),
  ...extra,
});

describe('answerCheckState', () => {
  it('is "checking" only while the streamed answer is being verified', () => {
    expect(answerCheckState(answer({ isStreaming: true }))).toBeNull();
    expect(answerCheckState(answer({ isStreaming: true, isVerifying: true }))).toBe('checking');
  });

  it('shows the verdict only when a check ran', () => {
    expect(answerCheckState(answer({ wasChecked: true, wasGrounded: true }))).toBe('grounded');
    expect(answerCheckState(answer({ wasChecked: true, wasGrounded: false }))).toBe('ungrounded');
    expect(answerCheckState(answer({ wasChecked: false, wasGrounded: true }))).toBeNull();
    expect(answerCheckState(answer({ wasGrounded: true }))).toBeNull(); // messages saved before this feature
  });

  it('never applies to user messages', () => {
    expect(answerCheckState(answer({ role: 'user', wasChecked: true, wasGrounded: true }))).toBeNull();
  });
});

describe('MessageBubble check line', () => {
  it('shows the animated checking line and hides the cursor while verifying', () => {
    const { container } = render(<MessageBubble message={answer({ isStreaming: true, isVerifying: true })} />);
    const line = screen.getByRole('status');
    expect(line).toHaveTextContent('Checking the answer against its sources…');
    expect(line).toHaveAttribute('data-state', 'checking');
    expect(container.querySelector('.answer-check-shimmer')).not.toBeNull();
    expect(container.querySelector('span.inline-block.animate-pulse')).toBeNull(); // typing cursor gone
  });

  it('shows no check line while tokens are still streaming', () => {
    render(<MessageBubble message={answer({ isStreaming: true })} />);
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('shows "Checked against sources" for a grounded answer', () => {
    render(<MessageBubble message={answer({ wasChecked: true, wasGrounded: true })} />);
    expect(screen.getByRole('status')).toHaveTextContent('Checked against sources');
    expect(screen.getByRole('status')).toHaveAttribute('data-state', 'grounded');
  });

  it('shows the warning for an answer that could not be verified', () => {
    render(<MessageBubble message={answer({ wasChecked: true, wasGrounded: false })} />);
    expect(screen.getByRole('status')).toHaveTextContent("Couldn't fully verify, check the sources");
    expect(screen.getByRole('status')).toHaveAttribute('data-state', 'ungrounded');
  });

  it('shows nothing when no check ran', () => {
    render(<MessageBubble message={answer({ wasChecked: false, wasGrounded: true })} />);
    expect(screen.queryByRole('status')).toBeNull();
  });
});
