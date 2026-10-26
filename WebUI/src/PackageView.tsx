import { useState } from 'react';
import type { Page } from './App';
import { message } from './App';
import * as api from './api';
import { bytes, t } from './i18n';
import { useAnswer } from './Lists';

/** One package: what the repositories say of it, and what can be done. */
export function PackageView({ page, id }: { page: Page; id: string }) {
  const { value, error } = useAnswer<api.PackageDetail>(page, 'package', { id }, [id]);
  const [version, setVersion] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [proposing, setProposing] = useState(false);

  const propose = async (args: object) => {
    setProposing(true);
    setFailure(null);
    try {
      await page.call('propose', args);
      page.showQueue();
    } catch (problem) {
      setFailure(message(problem));
    } finally {
      setProposing(false);
    }
  };

  const back = (
    <button className="btn plain" onClick={page.back}>
      ‹ {t('back')}
    </button>
  );
  if (error)
    return (
      <>
        <div className="toolbar">{back}</div>
        <p className="error">{error}</p>
      </>
    );
  if (!value) return <div className="toolbar">{back}</div>;

  const chosen = version ?? value.version;
  const installAction =
    value.installed === null ? t('install') : value.installed === chosen ? t('reinstall') : t('update');
  const fields: [string, string][] = [
    [t('version'), value.installed && value.installed !== value.version ? `${value.version} (${t('installedVersion', value.installed)})` : value.version],
    [t('section'), value.section],
    [t('author'), value.author],
    [t('maintainer'), value.maintainer],
    [t('repository'), value.repository],
    [t('size'), value.size ? bytes(value.size) : ''],
    [t('installedSize'), value.installedSize ? bytes(value.installedSize) : ''],
    [t('depends'), value.depends],
  ];

  return (
    <>
      <div className="toolbar">{back}</div>
      <div className="package">
        <h1>{value.name}</h1>
        <p className="muted mono">{value.id}</p>
        {value.summary && <p className="summary">{value.summary}</p>}
        <div className="actions">
          {value.versions.length > 1 && (
            <select aria-label={t('versions')} value={chosen} onChange={(event) => setVersion(event.target.value)}>
              {value.versions.map((each) => (
                <option key={each} value={each}>
                  {each}
                </option>
              ))}
            </select>
          )}
          <button
            className="btn primary"
            disabled={proposing}
            onClick={() => void propose({ install: [{ id: value.id, version: version }] })}
          >
            {installAction}
          </button>
          {value.installed !== null && (
            <button className="btn danger" disabled={proposing} onClick={() => void propose({ remove: [value.id] })}>
              {t('remove')}
            </button>
          )}
        </div>
        {failure && <p className="error">{failure}</p>}
        <dl className="fields">
          {fields
            .filter(([, text]) => text)
            .map(([label, text]) => (
              <div key={label}>
                <dt className="muted">{label}</dt>
                <dd>{text}</dd>
              </div>
            ))}
          {value.homepage && (
            <div>
              <dt className="muted">{t('homepage')}</dt>
              <dd>
                <a href={value.homepage} target="_blank" rel="noreferrer noopener">
                  {value.homepage}
                </a>
              </dd>
            </div>
          )}
        </dl>
        {value.description && value.description !== value.summary && (
          <p className="description">{value.description}</p>
        )}
      </div>
    </>
  );
}
