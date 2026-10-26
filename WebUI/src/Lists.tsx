import { useEffect, useState } from 'react';
import type { Page } from './App';
import { message } from './App';
import * as api from './api';
import { date, t } from './i18n';

/** A call's answer, read again whenever `deps` or the page's revision change. */
export function useAnswer<T>(page: Page, op: string, args: object, deps: unknown[]) {
  const [value, setValue] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let current = true;
    setLoading(true);
    page.call<T>(op, args).then(
      (answer) => {
        if (!current) return;
        setValue(answer);
        setError(null);
        setLoading(false);
      },
      (failure) => {
        if (!current) return;
        setError(message(failure));
        setLoading(false);
      },
    );
    return () => {
      current = false;
    };
  }, [op, page.revision, ...deps]);
  return { value, error, loading };
}

function Empty({ text }: { text: string }) {
  return <p className="muted empty">{text}</p>;
}

function Failure({ text }: { text: string }) {
  return <p className="error">{text}</p>;
}

export function SearchView({ page }: { page: Page }) {
  const [query, setQuery] = useState('');
  const [settled, setSettled] = useState('');
  useEffect(() => {
    const timer = setTimeout(() => setSettled(query.trim()), 250);
    return () => clearTimeout(timer);
  }, [query]);
  return (
    <>
      <div className="toolbar">
        <input
          type="search"
          placeholder={t('searchPlaceholder')}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          autoFocus
        />
      </div>
      {settled ? <SearchResults page={page} query={settled} /> : <Empty text={t('searchHint')} />}
    </>
  );
}

function SearchResults({ page, query }: { page: Page; query: string }) {
  const { value, error, loading } = useAnswer<api.SearchRow[]>(page, 'search', { query, limit: 100 }, [query]);
  if (error) return <Failure text={error} />;
  if (!value) return <Empty text={t('loading')} />;
  if (value.length === 0) return <Empty text={t('noResults')} />;
  return (
    <ul className={loading ? 'list loading' : 'list'}>
      {value.map((row) => (
        <li key={`${row.repository}/${row.id}`}>
          <button className="row" onClick={() => page.openPackage(row.id)}>
            <span className="row-title">
              <span className="name">{row.name}</span>
              <span className="muted mono">{row.version}</span>
            </span>
            <span className="row-detail muted">
              {row.installed ? `${t('installedVersion', row.installed)} · ` : ''}
              {row.summary || row.repository}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

export function UpdatesView({ page }: { page: Page }) {
  const { value, error } = useAnswer<api.UpdateRow[]>(page, 'updates', {}, []);
  const [proposing, setProposing] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  if (error) return <Failure text={error} />;
  if (!value) return <Empty text={t('loading')} />;
  const updateAll = async () => {
    setProposing(true);
    try {
      await page.call('propose', { updateAll: true });
      page.showQueue();
    } catch (problem) {
      setFailure(message(problem));
    } finally {
      setProposing(false);
    }
  };
  return (
    <>
      <div className="toolbar">
        <span className="spacer" />
        <button className="btn primary" disabled={value.length === 0 || proposing} onClick={() => void updateAll()}>
          {t('updateAll')}
        </button>
      </div>
      {failure && <Failure text={failure} />}
      {value.length === 0 ? (
        <Empty text={t('updatesEmpty')} />
      ) : (
        <ul className="list">
          {value.map((row) => (
            <li key={row.id}>
              <button className="row" onClick={() => page.openPackage(row.id)}>
                <span className="row-title">
                  <span className="name">{row.name}</span>
                  <span className="muted mono">{`${row.installed} → ${row.available}`}</span>
                </span>
                <span className="row-detail muted">{row.repository}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

export function InstalledView({ page }: { page: Page }) {
  const { value, error } = useAnswer<api.InstalledRow[]>(page, 'installed', {}, []);
  const [filter, setFilter] = useState('');
  if (error) return <Failure text={error} />;
  if (!value) return <Empty text={t('loading')} />;
  const needle = filter.trim().toLowerCase();
  const rows = needle
    ? value.filter((row) => row.name.toLowerCase().includes(needle) || row.id.includes(needle))
    : value;
  return (
    <>
      <div className="toolbar">
        <input type="search" placeholder={t('filter')} value={filter} onChange={(event) => setFilter(event.target.value)} />
      </div>
      {value.length === 0 ? (
        <Empty text={t('installedEmpty')} />
      ) : (
        <ul className="list">
          {rows.map((row) => (
            <li key={row.id}>
              <button className="row" onClick={() => page.openPackage(row.id)}>
                <span className="row-title">
                  <span className="name">{row.name}</span>
                  <span className="muted mono">{row.version}</span>
                </span>
                <span className="row-detail muted mono">{row.id}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

export function RepositoriesView({ page }: { page: Page }) {
  const [tick, setTick] = useState(0);
  const { value, error } = useAnswer<api.Repository[]>(page, 'repositories', {}, [tick]);
  const [address, setAddress] = useState('');
  const refreshing = value?.some((repository) => repository.refreshing) ?? false;

  // while anything refreshes, its state is read again every two seconds
  useEffect(() => {
    if (!refreshing) return;
    const timer = setTimeout(() => setTick((value) => value + 1), 2000);
    return () => clearTimeout(timer);
  }, [refreshing, value]);

  if (error) return <Failure text={error} />;
  if (!value) return <Empty text={t('loading')} />;
  return (
    <>
      <form
        className="toolbar"
        onSubmit={(event) => {
          event.preventDefault();
          const url = address.trim();
          if (!url) return;
          void page.ask('addRepository', { url }).then((request) => {
            if (request?.state === 'done') setAddress('');
          });
        }}
      >
        <input
          type="url"
          inputMode="url"
          autoCapitalize="off"
          autoCorrect="off"
          placeholder={t('repositoryAddress')}
          value={address}
          onChange={(event) => setAddress(event.target.value)}
        />
        <button className="btn" type="submit" disabled={!address.trim()}>
          {t('add')}
        </button>
        <button
          className="btn"
          type="button"
          disabled={refreshing}
          onClick={() => void page.call('refresh').then(() => setTick((value) => value + 1))}
        >
          {refreshing ? t('refreshing') : t('refresh')}
        </button>
      </form>
      {value.length === 0 ? (
        <Empty text={t('reposEmpty')} />
      ) : (
        <ul className="list">
          {value.map((repository) => (
            <li key={repository.url} className="row static">
              <span className="row-title">
                <span className="name">{repository.name}</span>
                <button
                  className="btn plain danger small"
                  onClick={() => void page.ask('removeRepository', { url: repository.url })}
                >
                  {t('remove')}
                </button>
              </span>
              <span className="row-detail muted mono">{repository.url}</span>
              <span className={repository.problem ? 'row-detail error' : 'row-detail muted'}>
                {repository.problem ??
                  [
                    t('packages', repository.packageCount),
                    repository.refreshing
                      ? t('refreshing')
                      : repository.refreshed
                        ? t('refreshed', date(repository.refreshed))
                        : t('neverRefreshed'),
                  ].join(' · ')}
              </span>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
