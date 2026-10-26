import { createRoot } from 'react-dom/client';
import { App } from './App';
import iconLight from './generated/icon-light.png';
import iconDark from './generated/icon-dark.png';
import { lang } from './i18n';
import './styles.css';

document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';

// The favicon is the app's icon, following the tab's colour scheme.
for (const [href, media, rel] of [
  [iconLight, '(prefers-color-scheme: light)', 'icon'],
  [iconDark, '(prefers-color-scheme: dark)', 'icon'],
  [iconLight, '', 'apple-touch-icon'],
]) {
  const link = document.createElement('link');
  link.rel = rel;
  link.href = href;
  if (media) link.media = media;
  document.head.append(link);
}

createRoot(document.getElementById('root')!).render(<App />);
