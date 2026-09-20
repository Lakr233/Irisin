/* The Irisin manual's scripts: the Blue Pencil template's three, loaded with
   `defer`. The theme itself is set before first paint by the inline snippet
   every page carries in <head> (see _skeleton.html); nothing here sets it on
   load. Every block stands on its own and does nothing on a page that lacks
   its parts: the contents page has no chapters, no rail and no figures. */
var IRISIN_MANUAL_THEME_KEY = 'irisin-manual-theme';

/* Contents rail: the active entry, the reading progress, and chapter links. */
(function () {
 var article = document.querySelector('article');
 if (!article) return;
 var chapters = Array.from(article.querySelectorAll('.chapter'));
 var links = Array.from(article.querySelectorAll('[data-chapter-link]'));
 var content = article.querySelector('.article-content');
 var bar = article.querySelector('.reading-progress');
 if (!chapters.length && !bar) return;
 /* Old chapter id -> new chapter id, so a renamed chapter's links still land. */
 var aliases = {};
 function syncContents() {
  var current = null;
  chapters.forEach(function (chapter) {
   if (chapter.getBoundingClientRect().top <= window.innerHeight * .3) current = chapter;
  });
  links.forEach(function (link) {
   if (current && link.dataset.chapterLink === current.id) link.setAttribute('aria-current','location');
   else link.removeAttribute('aria-current');
  });
  if (!content || !bar) return;
  var bounds = content.getBoundingClientRect();
  var distance = bounds.height - window.innerHeight + 40;
  var value = distance > 0 ? Math.max(0,Math.min(1,(40-bounds.top)/distance)) : (bounds.top < window.innerHeight ? 1 : 0);
  bar.style.setProperty('--reading-progress',String(value));
  bar.setAttribute('aria-valuenow',String(Math.round(value*100)));
 }
 function route() {
  var key;
  try { key = decodeURIComponent(location.hash.slice(1)); } catch (error) { key = ''; }
  var target = key ? document.getElementById(aliases[key] || key) : null;
  if (target && target.matches('.chapter')) {
   target.scrollIntoView({block:'start'});
   var heading = target.querySelector('h2');
   if (heading) heading.focus({preventScroll:true});
  }
  syncContents();
 }
 links.forEach(function (link) {
  link.addEventListener('click',function (event) {
   event.preventDefault();
   var url = new URL(location.href);
   url.hash = link.dataset.chapterLink;
   try { history.pushState(null,'',url); } catch (error) { location.hash = url.hash; }
   route();
  });
 });
 var pending = false;
 function scheduleProgress() {
  if (pending) return;
  pending = true;
  requestAnimationFrame(function () { pending = false; syncContents(); });
 }
 window.addEventListener('scroll',scheduleProgress,{passive:true});
 window.addEventListener('resize',scheduleProgress);
 window.addEventListener('hashchange',route);
 window.addEventListener('popstate',route);
 route();
})();

/* Underlines and figures draw in once, when scrolled to. */
(function () {
 if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
 var marks = document.querySelectorAll('.editorial-mark,.sk');
 if (!marks.length) return;
 var observer = new IntersectionObserver(function (entries) {
  entries.forEach(function (entry) {
   if (!entry.isIntersecting) return;
   entry.target.classList.add('mark-visible');
   observer.unobserve(entry.target);
  });
 }, {threshold:.35});
 marks.forEach(function (mark) {
  mark.classList.add('mark-pending');
  observer.observe(mark);
 });
})();

/* Theme toggle. The button's labels come from its own data attributes when a
   page gives them (the Chinese pages do), and are English otherwise. */
(function () {
 var button = document.querySelector('.theme-toggle');
 var systemTheme = window.matchMedia('(prefers-color-scheme: dark)');
 function syncThemeLabel() {
  if (!button) return;
  var dark = document.documentElement.dataset.theme === 'dark';
  var label = dark ? (button.dataset.labelLight || 'Switch to light mode') : (button.dataset.labelDark || 'Switch to dark mode');
  button.setAttribute('aria-label',label);
  button.title = label;
 }
 if (button) button.addEventListener('click',function () {
  var next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem(IRISIN_MANUAL_THEME_KEY,next); } catch (error) {}
  syncThemeLabel();
 });
 function followSystem(event) {
  var preferred;
  try { preferred = localStorage.getItem(IRISIN_MANUAL_THEME_KEY); } catch (error) {}
  if (preferred === 'light' || preferred === 'dark') return;
  document.documentElement.dataset.theme = event.matches ? 'dark' : 'light';
  syncThemeLabel();
 }
 if (systemTheme.addEventListener) systemTheme.addEventListener('change',followSystem);
 syncThemeLabel();
})();
