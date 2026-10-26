import { useState } from 'react';
import { t } from './i18n';

/** The six digits the device shows under its QR code. */
export function CodePrompt({ wrong, onCode }: { wrong: boolean; onCode: (code: string) => void }) {
  const [code, setCode] = useState('');
  const complete = /^\d{6}$/.test(code);
  return (
    <form
      className="code"
      onSubmit={(event) => {
        event.preventDefault();
        if (complete) onCode(code);
      }}
    >
      <h1>{t('codeTitle')}</h1>
      <p className="muted">{t('codeHint')}</p>
      <input
        className="code-input mono"
        inputMode="numeric"
        autoComplete="one-time-code"
        maxLength={6}
        value={code}
        onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))}
        aria-label={t('codeTitle')}
        autoFocus
      />
      {wrong && <p className="error">{t('codeWrong')}</p>}
      <button className="btn primary" type="submit" disabled={!complete}>
        {t('connect')}
      </button>
    </form>
  );
}
