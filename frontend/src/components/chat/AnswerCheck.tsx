import { AlertTriangle, Check, ShieldCheck } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { AnswerCheckState } from './answerCheckState';

const LABELS: Record<AnswerCheckState, string> = {
  checking: 'Checking the answer against its sources…',
  grounded: 'Checked against sources',
  ungrounded: "Couldn't fully verify, check the sources",
};

/**
 * One quiet line under an answer: an animated "checking" line while the backend
 * verifies the answer, then the result. Animation stops under prefers-reduced-motion.
 */
export function AnswerCheck({ state }: { state: AnswerCheckState }) {
  const Icon = state === 'checking' ? ShieldCheck : state === 'grounded' ? Check : AlertTriangle;

  return (
    <div
      role="status"
      aria-live="polite"
      data-state={state}
      className={cn(
        'mt-1.5 ml-1 flex items-center gap-2 text-xs animate-fade-in',
        state === 'checking' && 'text-primary font-medium',
        state === 'grounded' && 'text-muted-foreground',
        state === 'ungrounded' && 'text-amber-600 dark:text-amber-400',
      )}
    >
      <div
        className={cn(
          'w-5 h-5 rounded-full flex items-center justify-center',
          state === 'checking' && 'bg-primary/10 motion-safe:animate-pulse',
          state === 'grounded' && 'bg-green-500/10',
          state === 'ungrounded' && 'bg-amber-500/10',
        )}
      >
        <Icon
          aria-hidden="true"
          className={cn('w-3 h-3', state === 'grounded' && 'text-green-500')}
        />
      </div>
      <span className={cn(state === 'checking' && 'answer-check-shimmer')}>{LABELS[state]}</span>
    </div>
  );
}
