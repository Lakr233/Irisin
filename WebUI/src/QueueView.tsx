import { useEffect, useRef, useState } from 'react';
import type { Page } from './App';
import { message } from './App';
import * as api from './api';
import { bytes, step, t } from './i18n';
import { useAnswer } from './Lists';

/** The plan the device solved, waiting for the owner's yes there. */
export function QueueView({ page }: { page: Page }) {
  const { value: plan, error } = useAnswer<api.Plan | null>(page, 'plan', {}, []);
  const [failure, setFailure] = useState<string | null>(null);
  const [cleared, setCleared] = useState(false);
  if (error) return <p className="error">{error}</p>;
  if (plan === null || cleared || (plan.install.length === 0 && plan.remove.length === 0)) {
    return <p className="muted empty">{t('queueEmpty')}</p>;
  }
  return (
    <>
      <ul className="list">
        {plan.install.map((row) => (
          <li key={`install/${row.id}`} className="row static">
            <span className="row-title">
              <span className="name">{row.name}</span>
              <span className="muted mono">{row.version}</span>
            </span>
            <span className="row-detail muted">
              {[t('willInstall'), row.repository, row.size ? bytes(row.size) : ''].filter(Boolean).join(' · ')}
            </span>
          </li>
        ))}
        {plan.remove.map((row) => (
          <li key={`remove/${row.id}`} className="row static">
            <span className="row-title">
              <span className="name">{row.name}</span>
              <span className="muted mono">{row.version}</span>
            </span>
            <span className="row-detail danger-text">{t('willRemove')}</span>
          </li>
        ))}
      </ul>
      {plan.blocked && <p className="error">{plan.blocked}</p>}
      {plan.notes.map((note) => (
        <p key={note} className="muted note">
          {note}
        </p>
      ))}
      <div className="toolbar end">
        {plan.downloadSize > 0 && <span className="muted">{t('download', bytes(plan.downloadSize))}</span>}
        <span className="spacer" />
        <button
          className="btn"
          onClick={() =>
            void page.call('clear').then(
              () => setCleared(true),
              (problem) => setFailure(message(problem)),
            )
          }
        >
          {t('clear')}
        </button>
        <button
          className="btn primary"
          disabled={plan.blocked !== null}
          onClick={() => void page.ask('confirm', { plan: plan.id })}
        >
          {t('confirmOnDevice')}
        </button>
      </div>
      {failure && <p className="error">{failure}</p>}
    </>
  );
}

interface Run {
  steps: Map<string, string>;
  lines: string[];
  progress: { completed: number; total: number } | null;
  end: { succeeded: boolean } | null;
}

/** The running, or last, operation: a step per package and the transcript. */
export function OperationView({ keyBytes, onClose }: { keyBytes: Uint8Array; onClose: () => void }) {
  const [run, setRun] = useState<Run>({ steps: new Map(), lines: [], progress: null, end: null });
  const last = useRef(0);
  const transcript = useRef<HTMLPreElement>(null);

  useEffect(() => {
    const controller = new AbortController();
    let ended = false;
    const follow = async () => {
      // a dropped stream is asked again from the last frame it brought
      while (!ended && !controller.signal.aborted) {
        try {
          await api.stream(
            keyBytes,
            last.current,
            (frame) => {
              last.current = Math.max(last.current, frame.seq);
              setRun((current) => {
                const next: Run = { ...current };
                if (frame.line !== undefined) next.lines = [...current.lines, frame.line];
                if (frame.package && frame.step) next.steps = new Map(current.steps).set(frame.package, frame.step);
                if (frame.progress) next.progress = frame.progress;
                if (frame.end) {
                  ended = true;
                  next.end = { succeeded: frame.succeeded ?? false };
                }
                return next;
              });
            },
            controller.signal,
          );
          if (!ended) await new Promise((resolve) => setTimeout(resolve, 1000));
        } catch {
          if (controller.signal.aborted) return;
          await new Promise((resolve) => setTimeout(resolve, 1000));
        }
      }
    };
    void follow();
    return () => controller.abort();
  }, [keyBytes]);

  useEffect(() => {
    const box = transcript.current;
    if (box) box.scrollTop = box.scrollHeight;
  }, [run.lines.length]);

  const fraction = run.progress && run.progress.total > 0 ? run.progress.completed / run.progress.total : null;
  return (
    <div className="operation">
      <div className="toolbar">
        <h1>{t('operation')}</h1>
        <span className="spacer" />
        <span className={run.end && !run.end.succeeded ? 'error' : 'muted'}>
          {run.end ? (run.end.succeeded ? t('succeeded') : t('failed')) : t('running')}
        </span>
        {run.end && (
          <button className="btn" onClick={onClose}>
            {t('close')}
          </button>
        )}
      </div>
      <div className="meter" aria-hidden="true">
        {/* set through the CSSOM, which the page's style policy allows */}
        <div className="meter-fill" style={{ width: `${Math.round((run.end ? 1 : (fraction ?? 0)) * 100)}%` }} />
      </div>
      {run.steps.size > 0 && (
        <ul className="list">
          {[...run.steps].map(([id, name]) => (
            <li key={id} className="row static">
              <span className="row-title">
                <span className="name mono">{id}</span>
                <span className={name === 'failed' ? 'error' : 'muted'}>{step(name)}</span>
              </span>
            </li>
          ))}
        </ul>
      )}
      <h2 className="muted">{t('transcript')}</h2>
      <pre className="transcript mono" ref={transcript}>
        {run.lines.join('\n')}
      </pre>
    </div>
  );
}
