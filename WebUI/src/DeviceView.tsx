import { useState } from 'react';
import type { Page } from './App';
import { message } from './App';
import * as api from './api';
import { bytes, t } from './i18n';
import { useAnswer } from './Lists';

/** The device, and what Irisin keeps on it: its catalogue, its downloads, the rest. */
export function DeviceView({ page, device }: { page: Page; device: api.Device }) {
  const [tick, setTick] = useState(0);
  const { value: storage, error } = useAnswer<api.Storage>(page, 'storage', {}, [tick]);
  const [notice, setNotice] = useState<{ text: string; error: boolean } | null>(null);
  const [clearing, setClearing] = useState(false);

  const clear = async () => {
    setClearing(true);
    setNotice(null);
    try {
      await page.call('clearDownloads');
      setNotice({ text: t('downloadsCleared'), error: false });
      setTick((value) => value + 1);
    } catch (problem) {
      setNotice({ text: message(problem), error: true });
    } finally {
      setClearing(false);
    }
  };

  const facts: [string, string][] = [
    [t('model'), device.model],
    [t('system'), device.system],
    [t('bootstrap'), device.bootstrap],
    [t('architecture'), device.architecture],
    [t('irisinVersion'), device.irisinVersion],
    [t('service'), device.backend],
  ];
  const sizes: [string, number][] = storage
    ? [
        [t('storageTotal'), storage.total],
        [t('catalogue'), storage.catalogue],
        [t('downloads'), storage.downloads],
        [t('otherData'), storage.other],
        [t('freeSpace'), storage.freeSpace],
      ]
    : [];

  return (
    <div className="package">
      <h1>{device.name}</h1>
      {!device.canInstall && <p className="error">{t('browseOnly')}</p>}
      <dl className="fields">
        {facts
          .filter(([, text]) => text)
          .map(([label, text]) => (
            <div key={label}>
              <dt className="muted">{label}</dt>
              <dd className={label === t('service') ? 'mono' : undefined}>{text}</dd>
            </div>
          ))}
      </dl>
      <h2 className="muted">{t('storage')}</h2>
      {error && <p className="error">{error}</p>}
      {!storage && !error && <p className="muted">{t('loading')}</p>}
      {storage && (
        <dl className="fields">
          {sizes.map(([label, size]) => (
            <div key={label}>
              <dt className="muted">{label}</dt>
              <dd>{bytes(size)}</dd>
            </div>
          ))}
        </dl>
      )}
      <div className="actions">
        <button className="btn" disabled={clearing || device.busy || !storage?.downloads} onClick={() => void clear()}>
          {t('clearDownloads')}
        </button>
      </div>
      {notice && <p className={notice.error ? 'error' : 'muted'}>{notice.text}</p>}
    </div>
  );
}
