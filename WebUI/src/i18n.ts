// The page's words, in English and Chinese, chosen by the browser's language
// as Fila's page chooses. What a repository or the device writes (package
// names, descriptions, the transcript, a failure's reason) arrives already
// spelled and is shown as it is.
const en = {
  codeTitle: 'Enter the Code',
  codeHint: 'The six digits under the QR code on the device.',
  codeWrong: 'That code did not open the device. It shows a new one each time it starts serving.',
  connect: 'Connect',
  connecting: 'Connecting…',
  offline: 'The device cannot be reached. Check that Irisin is still open on it and on this network.',
  retry: 'Try Again',
  trust: 'Plain HTTP on the local network: use it on a network you trust.',
  search: 'Search',
  updates: 'Updates',
  installed: 'Installed',
  repositories: 'Repositories',
  queue: 'Queue',
  searchPlaceholder: 'Search packages',
  searchHint: 'Search the packages your repositories offer.',
  noResults: 'Nothing matches. Try other words.',
  installedVersion: (v: string) => `Installed ${v}`,
  version: 'Version',
  versions: 'Versions',
  section: 'Section',
  author: 'Author',
  maintainer: 'Maintainer',
  repository: 'Repository',
  size: 'Size',
  installedSize: 'Installed Size',
  depends: 'Depends',
  homepage: 'Homepage',
  install: 'Install',
  update: 'Update',
  remove: 'Remove',
  reinstall: 'Reinstall',
  back: 'Back',
  updatesEmpty: 'Everything is up to date.',
  updateAll: 'Update All',
  installedEmpty: 'Nothing is installed.',
  filter: 'Filter',
  reposEmpty: 'No repositories yet. Add one by its address.',
  repositoryAddress: 'Repository address',
  add: 'Add',
  refresh: 'Refresh',
  refreshing: 'Refreshing…',
  packages: (n: number) => (n === 1 ? '1 package' : `${n} packages`),
  refreshed: (when: string) => `Refreshed ${when}`,
  neverRefreshed: 'Not refreshed yet',
  queueEmpty: 'The queue is empty. Open a package to install, update or remove it.',
  willInstall: 'Install',
  willRemove: 'Remove',
  download: (size: string) => `${size} to download`,
  confirmOnDevice: 'Confirm on the Device',
  clear: 'Clear',
  asking: 'Waiting for the owner to confirm on the device.',
  declined: 'Declined on the device.',
  requestFailed: 'It did not go through.',
  requestDone: 'Done.',
  operation: 'Operation',
  running: 'Running…',
  succeeded: 'Completed.',
  failed: 'Failed.',
  transcript: 'Transcript',
  close: 'Close',
  respring: 'Reload Home Screen',
  busy: 'An operation is running on the device.',
  step: {
    waiting: 'Waiting',
    verifying: 'Verifying',
    removing: 'Removing',
    unpacking: 'Unpacking',
    configuring: 'Configuring',
    triggering: 'Processing triggers',
    done: 'Done',
    failed: 'Failed',
  } as Record<string, string>,
  dismiss: 'Dismiss',
  loading: 'Loading…',
};

type Words = typeof en;

const zh: Words = {
  codeTitle: '输入验证码',
  codeHint: '设备上二维码下方的六位数字。',
  codeWrong: '这个验证码打不开设备。设备每次开始服务都会显示新的验证码。',
  connect: '连接',
  connecting: '正在连接…',
  offline: '无法连接设备。请确认设备上的 Irisin 仍然打开，并且在同一网络。',
  retry: '重试',
  trust: '这是局域网内的明文 HTTP，请只在你信任的网络中使用。',
  search: '搜索',
  updates: '更新',
  installed: '已安装',
  repositories: '软件源',
  queue: '队列',
  searchPlaceholder: '搜索软件包',
  searchHint: '搜索软件源提供的软件包。',
  noResults: '没有匹配的结果，换个词试试。',
  installedVersion: (v) => `已安装 ${v}`,
  version: '版本',
  versions: '版本',
  section: '分区',
  author: '作者',
  maintainer: '维护者',
  repository: '软件源',
  size: '大小',
  installedSize: '安装后大小',
  depends: '依赖',
  homepage: '主页',
  install: '安装',
  update: '更新',
  remove: '卸载',
  reinstall: '重新安装',
  back: '返回',
  updatesEmpty: '一切都是最新的。',
  updateAll: '全部更新',
  installedEmpty: '没有安装任何软件包。',
  filter: '筛选',
  reposEmpty: '还没有软件源。输入地址添加一个。',
  repositoryAddress: '软件源地址',
  add: '添加',
  refresh: '刷新',
  refreshing: '正在刷新…',
  packages: (n) => `${n} 个软件包`,
  refreshed: (when) => `刷新于 ${when}`,
  neverRefreshed: '尚未刷新',
  queueEmpty: '队列是空的。打开一个软件包来安装、更新或卸载。',
  willInstall: '安装',
  willRemove: '卸载',
  download: (size) => `需下载 ${size}`,
  confirmOnDevice: '在设备上确认',
  clear: '清空',
  asking: '正在等待设备主人在设备上确认。',
  declined: '已在设备上拒绝。',
  requestFailed: '没有完成。',
  requestDone: '已完成。',
  operation: '操作',
  running: '正在进行…',
  succeeded: '已完成。',
  failed: '失败。',
  transcript: '记录',
  close: '关闭',
  respring: '重新载入主屏幕',
  busy: '设备上有一项操作正在进行。',
  step: {
    waiting: '等待中',
    verifying: '校验中',
    removing: '卸载中',
    unpacking: '解包中',
    configuring: '配置中',
    triggering: '处理触发器',
    done: '完成',
    failed: '失败',
  },
  dismiss: '关闭',
  loading: '正在载入…',
};

export const lang: 'en' | 'zh' = navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
const words = lang === 'zh' ? zh : en;

type Plain = { [K in keyof Words]: Words[K] extends string ? K : never }[keyof Words];
type Formatted = { [K in keyof Words]: Words[K] extends (...a: never[]) => string ? K : never }[keyof Words];

export function t(key: Plain): string;
export function t<K extends Formatted>(key: K, ...args: Parameters<Words[K]>): string;
export function t(key: keyof Words, ...args: unknown[]): string {
  const value = words[key];
  return typeof value === 'function' ? (value as (...a: unknown[]) => string)(...args) : String(value);
}

export function step(name: string): string {
  return words.step[name] ?? name;
}

export function bytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do {
    n /= 1024;
    i++;
  } while (n >= 1024 && i < units.length - 1);
  return `${new Intl.NumberFormat(lang, { maximumFractionDigits: 1 }).format(n)} ${units[i]}`;
}

export function date(value: string | null): string {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime())
    ? '—'
    : new Intl.DateTimeFormat(lang, { dateStyle: 'medium', timeStyle: 'short' }).format(d);
}
