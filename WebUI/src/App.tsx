import { useCallback, useEffect, useRef, useState } from 'react';
import * as api from './api';
import { CodePrompt } from './CodePrompt';
import iconDark from './generated/icon-dark.png';
import iconLight from './generated/icon-light.png';
import { t } from './i18n';
import { InstalledView, RepositoriesView, SearchView, UpdatesView } from './Lists';
import { PackageView } from './PackageView';
import { OperationView, QueueView } from './QueueView';

export type Tab = 'search' | 'updates' | 'installed' | 'repositories' | 'queue';
const TABS: Tab[] = ['search', 'updates', 'installed', 'repositories', 'queue'];

type Route = { tab: Tab; pkg?: string };

/** What every view is handed: the device's calls and the page's navigation. */
export interface Page {
  call<T>(op: string, args?: object): Promise<T>;
  /** A change the owner confirms on the device; resolves once it is settled. */
  ask(op: string, args?: object): Promise<api.Request | null>;
  openPackage(id: string): void;
  showQueue(): void;
  back(): void;
  /** Bumped when a request settles, so lists read the device again. */
  revision: number;
}

const STORED = 'irisin.key';

interface Stored {
  salt: string;
  key: string;
}

function storedKey(salt: string): Uint8Array | null {
  try {
    const value = JSON.parse(localStorage.getItem(STORED) ?? 'null') as Stored | null;
    return value && value.salt === salt ? api.decodeKey(value.key) : null;
  } catch {
    return null;
  }
}

function storeKey(salt: string, key: Uint8Array) {
  try {
    localStorage.setItem(STORED, JSON.stringify({ salt, key: api.encodeKey(key) }));
  } catch {
    // a private window keeps nothing; the code is asked for again
  }
}

/** The code from the QR code's URL, read once and cleared from the address bar. */
function codeFromLocation(): string | null {
  const match = location.hash.match(/^#(\d{6})$/);
  if (location.hash) history.replaceState(null, '', location.pathname);
  return match ? match[1] : null;
}

type State =
  | { kind: 'connecting' }
  | { kind: 'code'; wrong: boolean }
  | { kind: 'offline' }
  | { kind: 'ready'; key: Uint8Array; device: api.Device };

export function App() {
  const [state, setState] = useState<State>({ kind: 'connecting' });
  const salt = useRef<string>('');

  const tryKey = useCallback(async (key: Uint8Array) => {
    try {
      const device = await api.call<api.Device>(key, 'device');
      storeKey(salt.current, key);
      setState({ kind: 'ready', key, device });
    } catch (error) {
      setState(error instanceof api.Unauthorized ? { kind: 'code', wrong: true } : { kind: 'offline' });
    }
  }, []);

  const start = useCallback(async () => {
    setState({ kind: 'connecting' });
    const code = codeFromLocation();
    try {
      salt.current = (await api.hello()).salt;
    } catch {
      setState({ kind: 'offline' });
      return;
    }
    const key = code ? api.deriveKey(code, salt.current) : storedKey(salt.current);
    if (key) {
      await tryKey(key);
    } else {
      setState({ kind: 'code', wrong: false });
    }
  }, [tryKey]);

  useEffect(() => {
    void start();
  }, [start]);

  switch (state.kind) {
    case 'connecting':
      return <Shell>{<p className="muted">{t('connecting')}</p>}</Shell>;
    case 'offline':
      return (
        <Shell>
          <p className="error">{t('offline')}</p>
          <button className="btn" onClick={() => void start()}>
            {t('retry')}
          </button>
        </Shell>
      );
    case 'code':
      return (
        <Shell>
          <CodePrompt wrong={state.wrong} onCode={(code) => void tryKey(api.deriveKey(code, salt.current))} />
        </Shell>
      );
    case 'ready':
      return <Manager keyBytes={state.key} device={state.device} onLost={() => setState({ kind: 'code', wrong: true })} />;
  }
}

function Shell({ children, device, actions }: { children: React.ReactNode; device?: api.Device; actions?: React.ReactNode }) {
  return (
    <>
      <header className="header">
        <div className="brand">
          <picture>
            <source srcSet={iconDark} media="(prefers-color-scheme: dark)" />
            <img className="brand-mark" src={iconLight} alt="" />
          </picture>
          <span>Irisin</span>
          {device && <span className="muted device">{`${device.name} · ${device.system}`}</span>}
        </div>
        {actions}
      </header>
      <main className="main">{children}</main>
    </>
  );
}

function Manager({ keyBytes, device: initial, onLost }: { keyBytes: Uint8Array; device: api.Device; onLost: () => void }) {
  const [device, setDevice] = useState(initial);
  const [route, setRoute] = useState<Route>({ tab: 'search' });
  const [notice, setNotice] = useState<{ text: string; error: boolean } | null>(null);
  const [revision, setRevision] = useState(0);
  const [operation, setOperation] = useState(initial.busy);

  const call = useCallback(
    async <T,>(op: string, args?: object): Promise<T> => {
      try {
        return await api.call<T>(keyBytes, op, args);
      } catch (error) {
        if (error instanceof api.Unauthorized) onLost();
        throw error;
      }
    },
    [keyBytes, onLost],
  );

  const ask = useCallback(
    async (op: string, args?: object): Promise<api.Request | null> => {
      let request: api.Request;
      try {
        request = await call<api.Request>(op, args);
      } catch (error) {
        setNotice({ text: message(error), error: true });
        return null;
      }
      setNotice({ text: t('asking'), error: false });
      while (request.state === 'asking' || request.state === 'running') {
        if (request.state === 'running' && op === 'confirm') setOperation(true);
        await new Promise((resolve) => setTimeout(resolve, 1000));
        try {
          request = await call<api.Request>('request', { id: request.id });
        } catch (error) {
          if (!(error instanceof api.Offline)) {
            setNotice({ text: message(error), error: true });
            return null;
          }
        }
      }
      setRevision((value) => value + 1);
      switch (request.state) {
        case 'declined':
          setNotice({ text: t('declined'), error: true });
          break;
        case 'failed':
          setNotice({ text: request.detail ?? t('requestFailed'), error: true });
          break;
        default:
          setNotice(op === 'confirm' ? null : { text: request.detail ?? t('requestDone'), error: false });
      }
      return request;
    },
    [call],
  );

  // the device's name and whether it is busy, read again now and then
  useEffect(() => {
    const timer = setInterval(async () => {
      try {
        const next = await call<api.Device>('device');
        setDevice(next);
        if (next.busy) setOperation(true);
      } catch {
        // the next tick tries again
      }
    }, 5000);
    return () => clearInterval(timer);
  }, [call]);

  const page: Page = {
    call,
    ask,
    openPackage: (id) => setRoute((current) => ({ tab: current.tab, pkg: id })),
    showQueue: () => setRoute({ tab: 'queue' }),
    back: () => setRoute((current) => ({ tab: current.tab })),
    revision,
  };

  const actions = (
    <button className="btn plain" disabled={device.busy} onClick={() => void ask('respring')}>
      {t('respring')}
    </button>
  );

  return (
    <Shell device={device} actions={actions}>
      <nav className="tabs">
        {TABS.map((tab) => (
          <button
            key={tab}
            className={route.tab === tab && !route.pkg ? 'tab current' : 'tab'}
            onClick={() => setRoute({ tab })}
          >
            {t(tab)}
          </button>
        ))}
      </nav>
      {notice && (
        <div className={notice.error ? 'notice error' : 'notice'} role="status">
          <span>{notice.text}</span>
          <button aria-label={t('dismiss')} onClick={() => setNotice(null)}>
            ×
          </button>
        </div>
      )}
      {operation ? (
        <OperationView
          keyBytes={keyBytes}
          onClose={() => {
            setOperation(false);
            setRevision((value) => value + 1);
          }}
        />
      ) : route.pkg ? (
        <PackageView page={page} id={route.pkg} />
      ) : (
        <View tab={route.tab} page={page} />
      )}
      <p className="muted footnote">{t('trust')}</p>
    </Shell>
  );
}

function View({ tab, page }: { tab: Tab; page: Page }) {
  switch (tab) {
    case 'search':
      return <SearchView page={page} />;
    case 'updates':
      return <UpdatesView page={page} />;
    case 'installed':
      return <InstalledView page={page} />;
    case 'repositories':
      return <RepositoriesView page={page} />;
    case 'queue':
      return <QueueView page={page} />;
  }
}

export function message(error: unknown): string {
  if (error instanceof api.Refused) return error.message;
  if (error instanceof api.Offline) return t('offline');
  if (error instanceof api.Unauthorized) return t('codeWrong');
  return String(error);
}
