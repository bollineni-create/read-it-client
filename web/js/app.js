// Rounds for the web: sidebar of scopes and subreddits, ranked thread list, thread detail.
'use strict';

const SYNC_INTERVALS = { hourly: ['Every hour', 3600e3], sixHours: ['Every 6 hours', 6 * 3600e3], daily: ['Daily', 86400e3], manual: ['Manual', null] };
const SORTS = { relevance: 'Relevance', top: 'Top', discussed: 'Most discussed' };

const store = { subs: [], threads: new Map(), settings: null, syncInterval: 'sixHours', lastSyncAll: 0 };
const ui = { scope: { type: 'all' }, sort: 'relevance', query: '', selected: null, view: 'list', syncing: false, progress: '', searchDocs: null };

const $ = (s, root = document) => root.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const subById = (id) => store.subs.find((s) => s.id === id);
const fmtNum = (n) => compact(n || 0);

// MARK: Markdown (Reddit's subset, rendered from escaped text so nothing in a post can inject HTML)

function inlineMd(text) {
  let s = esc(text);
  const codes = [];
  s = s.replace(/`([^`\n]+)`/g, (_, c) => `\u0000${codes.push(`<code>${c}</code>`) - 1}\u0000`);
  s = s.replace(/\[([^\]\n]{1,300})\]\((https?:\/\/[^\s)]+(?:\([^\s)]*\)[^\s)]*)*)\)/g, (_, t, u) => `<a href="${u}" target="_blank" rel="noopener noreferrer">${t}</a>`);
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<]+[^\s<.,;:!?)'"])/g, (_, pre, u) => `${pre}<a href="${u}" target="_blank" rel="noopener noreferrer">${u}</a>`);
  s = s.replace(/(^|[\s(])\/?(r\/[A-Za-z0-9_]{2,21})\b/g, (_, pre, r) => `${pre}<a href="https://www.reddit.com/${r}" target="_blank" rel="noopener noreferrer">${r}</a>`);
  s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>').replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, '$1<em>$2</em>').replace(/(^|[^_\w])_([^_\n]+)_(?!\w)/g, '$1<em>$2</em>');
  s = s.replace(/~~([^~\n]+)~~/g, '<del>$1</del>').replace(/&gt;!(.+?)!&lt;/g, '<span class="spoiler" tabindex="0">$1</span>');
  s = s.replace(/\\([*_~`>#\\()[\]])/g, '$1');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[i]);
}

function renderMarkdown(src) {
  const lines = (src || '').replace(/\r/g, '').split('\n');
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    if (/^```/.test(line.trim()) || /^ {4}\S/.test(line)) {
      const fenced = /^```/.test(line.trim());
      const buf = [];
      if (fenced) { i++; while (i < lines.length && !/^```/.test(lines[i].trim())) buf.push(lines[i++]); i++; }
      else while (i < lines.length && (/^ {4}/.test(lines[i]) || !lines[i].trim())) buf.push(lines[i++].slice(4));
      out.push(`<pre><code>${esc(buf.join('\n').replace(/\n+$/, ''))}</code></pre>`);
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { out.push(`<h${Math.min(h[1].length + 2, 6)}>${inlineMd(h[2])}</h${Math.min(h[1].length + 2, 6)}>`); i++; continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { out.push('<hr>'); i++; continue; }
    if (/^\s*>/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ''));
      out.push(`<blockquote>${renderMarkdown(buf.join('\n'))}</blockquote>`);
      continue;
    }
    const listRe = /^\s*([-*+]|\d+[.)])\s+/;
    if (listRe.test(line)) {
      const ordered = /^\s*\d/.test(line);
      const items = [];
      while (i < lines.length && (listRe.test(lines[i]) || (lines[i].trim() && /^\s{2,}/.test(lines[i]) && items.length))) {
        if (listRe.test(lines[i])) items.push(lines[i].replace(listRe, '')); else items[items.length - 1] += ' ' + lines[i].trim();
        i++;
      }
      out.push(`<${ordered ? 'ol' : 'ul'}>${items.map((t) => `<li>${inlineMd(t)}</li>`).join('')}</${ordered ? 'ol' : 'ul'}>`);
      continue;
    }
    if (line.includes('|') && i + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) {
      const cells = (l) => l.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes('|') && lines[i].trim()) rows.push(cells(lines[i++]));
      out.push(`<div class="table"><table><thead><tr>${head.map((c) => `<th>${inlineMd(c)}</th>`).join('')}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${inlineMd(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`);
      continue;
    }
    const buf = [];
    while (i < lines.length && lines[i].trim() && !listRe.test(lines[i]) && !/^\s*>/.test(lines[i]) && !/^#{1,6}\s/.test(lines[i]) && !/^```/.test(lines[i].trim())) buf.push(lines[i++]);
    out.push(`<p>${buf.map((l) => inlineMd(l.replace(/ {2,}$/, ''))).join(buf.length > 1 ? '<br>' : '')}</p>`);
  }
  return out.join('');
}

// MARK: Queries

function inScope(t, scope) {
  const sub = subById(t.sub);
  switch (scope.type) {
    case 'saved': return t.isSaved;
    case 'sub': return t.sub === scope.id;
    case 'resources': return t.kind === 'resource' && ((sub && sub.isEnabled) || t.isSaved);
    default: return (sub && sub.isEnabled) || t.isSaved;
  }
}

function passesFilters(t) {
  if (t.isSaved) return true;
  const sub = subById(t.sub);
  if (sub && !sub.includeKinds.includes(t.kind)) return false;
  if (t.score < store.settings.minimumUpvotes) return false;
  if (store.settings.hideImageAndMemePosts && t.isImageOnly) return false;
  return true;
}

function scoped(scope) {
  return [...store.threads.values()].filter((t) => inScope(t, scope) && (scope.type === 'saved' || passesFilters(t)));
}

async function searchDocs() {
  if (ui.searchDocs) return ui.searchDocs;
  const details = new Map((await DB.all('details')).map((d) => [d.id, d]));
  ui.searchDocs = [...store.threads.values()].map((t) => {
    const d = details.get(t.id);
    return {
      id: t.id,
      tokens: {
        title: tokenize(t.title), body: tokenize(t.body),
        comments: tokenize((d?.comments || []).map((c) => c.body).join('\n')),
        resources: tokenize((d?.resources || []).map((r) => `${r.title} ${r.domain} ${r.url}`).join('\n')),
      },
    };
  });
  return ui.searchDocs;
}

async function visibleThreads() {
  let list = scoped(ui.scope);
  let scores = null;
  if (ui.query.trim()) {
    const docs = await searchDocs();
    const ids = new Set(list.map((t) => t.id));
    scores = searchScores(docs.filter((d) => ids.has(d.id)), ui.query);
    if (scores) list = list.filter((t) => scores.has(t.id));
  }
  const tie = (a, b) => b.createdUTC - a.createdUTC;
  if (ui.sort === 'top') list.sort((a, b) => b.score - a.score || tie(a, b));
  else if (ui.sort === 'discussed') list.sort((a, b) => b.numComments - a.numComments || tie(a, b));
  else if (scores) list.sort((a, b) => (scores.get(b.id) + b.relevance / 20) - (scores.get(a.id) + a.relevance / 20) || tie(a, b));
  else list.sort((a, b) => b.relevance - a.relevance || tie(a, b));
  return list;
}

// MARK: Rendering

function scopeLabel(scope) {
  if (scope.type === 'sub') return `r/${subById(scope.id)?.name || scope.id}`;
  return { all: 'All threads', resources: 'Resources', saved: 'Saved' }[scope.type];
}

function renderSidebar() {
  const counts = (scope) => scoped(scope).length;
  const item = (scope, label, icon, count, extra = '') => {
    const active = ui.scope.type === scope.type && ui.scope.id === scope.id;
    return `<button class="side-item${active ? ' active' : ''}" data-scope="${scope.type}" data-id="${esc(scope.id || '')}" ${extra}>
      ${icon}<span class="side-label">${label}</span><span class="count">${count}</span></button>`;
  };
  const icons = {
    all: '<svg viewBox="0 0 20 20" class="ico"><path d="M3 5h14M3 10h14M3 15h9" /></svg>',
    resources: '<svg viewBox="0 0 20 20" class="ico"><path d="M8 12l4-4M7 9l-2 2a3 3 0 004 4l2-2M13 11l2-2a3 3 0 00-4-4l-2 2" /></svg>',
    saved: '<svg viewBox="0 0 20 20" class="ico"><path d="M6 3h8v14l-4-3-4 3z" /></svg>',
  };
  const subs = [...store.subs].sort((a, b) => a.sortIndex - b.sortIndex);
  $('#sidebar').innerHTML = `
    <div class="side-group">
      ${item({ type: 'all' }, 'All threads', icons.all, counts({ type: 'all' }))}
      ${item({ type: 'resources' }, 'Resources', icons.resources, counts({ type: 'resources' }))}
      ${item({ type: 'saved' }, 'Saved', icons.saved, counts({ type: 'saved' }))}
    </div>
    <div class="side-head"><span>Subreddits</span><button class="icon-btn small" id="add-sub" title="Add a subreddit" aria-label="Add a subreddit">+</button></div>
    <div class="side-group">
      ${subs.map((s) => `<div class="side-row${s.isEnabled ? '' : ' disabled'}">
        ${item({ type: 'sub', id: s.id }, `r/${esc(s.name)}`, `<span class="dot" style="background:${s.colorHex}"></span>`, counts({ type: 'sub', id: s.id }),
          s.lastError ? `title="${esc(s.lastError)}"` : '')}
        ${s.lastError ? '<span class="warn" title="' + esc(s.lastError) + '">!</span>' : ''}
        <button class="icon-btn small edit-sub" data-id="${esc(s.id)}" title="Edit r/${esc(s.name)}" aria-label="Edit r/${esc(s.name)}">⋯</button>
      </div>`).join('') || '<p class="side-empty">No subreddits yet.</p>'}
    </div>
    <div class="side-foot">${esc(syncLine())}</div>`;
}

function syncLine() {
  if (ui.syncing) return ui.progress || 'Syncing…';
  const last = Math.max(0, ...store.subs.map((s) => s.lastSynced || 0));
  const mode = Reddit.mode === 'server' ? ' · Reddit API' : '';
  return last ? (Date.now() - last < 60e3 ? `Synced just now${mode}` : `Synced ${shortAge(last)} ago${mode}`) : 'Not synced yet';
}

async function renderList() {
  const list = await visibleThreads();
  $('#list-title').textContent = scopeLabel(ui.scope);
  $('#list-count').textContent = `${list.length} thread${list.length === 1 ? '' : 's'}`;
  $('#sort').value = ui.sort;
  const el = $('#threads');
  if (!list.length) {
    el.innerHTML = `<div class="empty">${emptyState()}</div>`;
    return list;
  }
  const now = Date.now();
  el.innerHTML = list.slice(0, 400).map((t) => {
    const sub = subById(t.sub);
    return `<button class="row${ui.selected === t.id ? ' selected' : ''}" data-id="${t.id}">
      <div class="row-meta"><span class="dot" style="background:${sub?.colorHex || '#888'}"></span>r/${esc(sub?.name || t.subName)} · ${KINDS[t.kind]} · ${shortAge(t.createdUTC, now)}${t.isSaved ? ' · <span class="saved-mark">Saved</span>' : ''}</div>
      <div class="row-title">${esc(t.title)}</div>
      <div class="row-stats"><span title="Upvotes">↑ ${fmtNum(t.score)}</span><span title="Comments">💬 ${fmtNum(t.numComments)}</span>${t.linkCount ? `<span title="Links">🔗 ${t.linkCount}</span>` : ''}<span class="rel" title="Relevance">${t.relevance.toFixed(0)}</span></div>
    </button>`;
  }).join('');
  return list;
}

function emptyState() {
  if (ui.query.trim()) return `<h3>No matches</h3><p>Nothing in ${esc(scopeLabel(ui.scope))} matches “${esc(ui.query)}”.</p>`;
  if (ui.syncing) return `<div class="spinner"></div><h3>Syncing</h3><p>${esc(ui.progress)}</p>`;
  if (ui.scope.type === 'saved') return '<h3>Nothing saved</h3><p>Save a thread to keep it here, even after it drops out of the top posts.</p>';
  if (ui.scope.type === 'sub') {
    const s = subById(ui.scope.id);
    if (s?.lastError) return `<h3>Couldn't sync r/${esc(s.name)}</h3><p>${esc(s.lastError)}</p><button class="btn" data-action="sync">Try again</button>`;
  }
  if (!store.subs.length) return '<h3>No subreddits</h3><p>Add a subreddit to start.</p><button class="btn" data-action="add-sub">Add a subreddit</button>';
  const errs = store.subs.filter((s) => s.lastError);
  if (errs.length && !store.threads.size) return `<h3>Couldn't sync</h3><p>${esc(errs[0].lastError)}</p><button class="btn" data-action="sync">Try again</button>`;
  if (!store.threads.size) return '<h3>No threads yet</h3><p>Sync to pull the top threads from your subreddits.</p><button class="btn" data-action="sync">Sync now</button>';
  return '<h3>No threads</h3><p>Nothing here passes your filters. Lower the minimum upvotes in Settings to see more.</p>';
}

async function renderDetail() {
  const el = $('#detail');
  const t = ui.selected && store.threads.get(ui.selected);
  if (!t) {
    el.innerHTML = '<div class="empty"><h3>Select a thread</h3><p>Pick a thread to read it, with its comments and the links people shared.</p></div>';
    return;
  }
  const sub = subById(t.sub);
  const detail = (await DB.get('details', t.id)) || { comments: [], resources: [] };
  const redditURL = 'https://www.reddit.com' + t.permalink;
  const date = new Date(t.createdUTC).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  const outbound = t.postURL && !isRedditURL(t.postURL) && t.postURL !== redditURL ? t.postURL : null;
  el.innerHTML = `
    <button class="back" data-action="back">‹ ${esc(scopeLabel(ui.scope))}</button>
    <article>
      <div class="d-meta"><span class="dot" style="background:${sub?.colorHex || '#888'}"></span>r/${esc(sub?.name || t.subName)} · ${KINDS[t.kind]} · u/${esc(t.author)} · ${date}</div>
      <h1 class="d-title">${esc(t.title)}</h1>
      <div class="d-actions">
        <span class="stat">↑ ${fmtNum(t.score)}</span><span class="stat">💬 ${fmtNum(t.numComments)}</span>${t.linkCount ? `<span class="stat">🔗 ${t.linkCount}</span>` : ''}
        <span class="spacer"></span>
        <a class="btn ghost" href="${esc(redditURL)}" target="_blank" rel="noopener noreferrer">Open on Reddit</a>
        <button class="btn${t.isSaved ? ' on' : ''}" data-action="save">${t.isSaved ? 'Saved' : 'Save'}</button>
      </div>
      ${t.why ? `<div class="why"><span class="why-label">Why it surfaced</span><span class="why-score">${t.relevance.toFixed(1)}</span><p>${esc(t.why)}</p></div>` : ''}
      ${t.body.trim() ? `<div class="md">${renderMarkdown(t.body)}</div>` : ''}
      ${outbound ? `<a class="outbound" href="${esc(outbound)}" target="_blank" rel="noopener noreferrer"><span>${esc(domainOf(outbound))}</span>${esc(outbound)}</a>` : ''}
      ${detail.resources.length ? `<section><h2>Resources in this thread</h2><ul class="resources">${detail.resources.map((r) => `
        <li><a href="${esc(r.url)}" target="_blank" rel="noopener noreferrer"><span class="r-title">${esc(r.title)}</span>
        <span class="r-domain">${esc(r.domain)} · ${r.sourceCommentId ? 'in comments' : 'in post'}</span></a></li>`).join('')}</ul></section>` : ''}
      <section><h2>Comments</h2>${detail.comments.length ? `<ol class="comments">${detail.comments.map((c) => `
        <li class="comment" style="--depth:${Math.min(c.depth, 8)}"><div class="c-meta">u/${esc(c.author)} · ↑ ${fmtNum(c.score)}</div><div class="md">${renderMarkdown(c.body)}</div></li>`).join('')}</ol>`
        : t.commentsFetchedAt ? '<p class="muted">No comments yet.</p>' : '<p class="muted">Comments haven\'t been fetched for this thread.</p><button class="btn" data-action="load-comments">Load comments</button>'}</section>
    </article>`;
  el.scrollTop = 0;
}

const domainOf = (u) => { try { return new URL(u).hostname.replace(/^www\./, ''); } catch { return ''; } };

async function render() {
  renderSidebar();
  await renderList();
  await renderDetail();
  document.body.dataset.view = ui.view;
  $('#sync').disabled = ui.syncing;
  $('#sync').classList.toggle('busy', ui.syncing);
}

// MARK: Actions

async function persistSettings() {
  await DB.setKV('settings', store.settings);
  await DB.setKV('syncInterval', store.syncInterval);
}

async function syncAll({ full = true, only = null } = {}) {
  if (ui.syncing) return;
  ui.syncing = true;
  ui.progress = 'Connecting to Reddit…';
  render();
  await Reddit.detect();
  const subs = only ? [only] : store.subs.filter((s) => s.isEnabled);
  for (const sub of subs) {
    try {
      await syncSubreddit(store, sub, { full, onProgress: (p) => { ui.progress = p; renderSidebar(); if (!store.threads.size) renderList(); } });
    } catch (e) { console.warn(`r/${sub.name}:`, e.message); }
    ui.searchDocs = null;
    renderSidebar();
    await renderList();
  }
  if (!only) { store.lastSyncAll = Date.now(); await DB.setKV('lastSyncAll', store.lastSyncAll); }
  ui.syncing = false;
  ui.progress = '';
  render();
}

function maybeAutoSync() {
  const interval = SYNC_INTERVALS[store.syncInterval]?.[1];
  if (interval && Date.now() - store.lastSyncAll > interval) syncAll({ full: false });
}

async function toggleSave(id) {
  const t = store.threads.get(id);
  t.isSaved = !t.isSaved;
  await DB.put('threads', t);
  render();
}

async function loadComments(id) {
  const t = store.threads.get(id);
  const btn = $('[data-action="load-comments"]');
  if (btn) { btn.disabled = true; btn.textContent = 'Loading…'; }
  try {
    const res = await Reddit.comments(id, store.settings.commentsPerThread || 500);
    const built = buildThread(res.post || { ...t, subreddit: t.subName, selftext: t.body, createdUTC: t.createdUTC / 1000 }, t.sub, res.tree, store.settings.commentsPerThread || null, t);
    await DB.put('details', { id, comments: built.comments, resources: built.resources });
    store.threads.set(id, built.thread);
    const sub = subById(t.sub);
    if (sub) await rescoreSubreddit(store, sub); else await DB.put('threads', built.thread);
    ui.searchDocs = null;
  } catch (e) {
    toast(e.message);
  }
  render();
}

function select(id) {
  ui.selected = id;
  ui.view = id ? 'detail' : 'list';
  renderDetail();
  document.body.dataset.view = ui.view;
  for (const r of document.querySelectorAll('.row')) r.classList.toggle('selected', r.dataset.id === id);
}

function setScope(scope) {
  ui.scope = scope;
  ui.selected = null;
  ui.view = 'list';
  document.body.classList.remove('drawer-open');
  render();
}

let toastTimer;
function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 4000);
}

// MARK: Dialogs

function openAddSub() {
  const d = $('#dlg-add');
  const existing = store.subs.map((s) => s.name);
  $('#add-input').value = '';
  $('#add-error').textContent = '';
  $('#add-suggest').innerHTML = [...DEFAULT_SUBS, ...SUGGESTED_SUBS].filter((n) => !existing.some((e) => e.toLowerCase() === n.toLowerCase()))
    .map((n) => `<button type="button" class="chip" data-name="${n}">r/${n}</button>`).join('');
  d.showModal();
  $('#add-input').focus();
}

async function submitAddSub(e) {
  e.preventDefault();
  const parsed = parseSubredditName($('#add-input').value, store.subs.map((s) => s.name));
  const err = $('#add-error');
  if (parsed.error) { err.textContent = parsed.error; return; }
  const btn = $('#add-ok');
  btn.disabled = true;
  err.textContent = '';
  let name = parsed.name;
  try {
    const about = await Reddit.about(name);
    if (about.type === 'private') throw Object.assign(new Error(`r/${name} is private.`), { status: 403 });
    if (about.name) name = about.name;
  } catch (ex) {
    if (ex.status === 404 || ex.status === 403) { err.textContent = ex.message; btn.disabled = false; return; }
    // Unreachable for now: add it anyway; the sync will report the problem.
  }
  btn.disabled = false;
  const sub = newSubreddit(name, store.subs.length, { sortIndex: Math.max(-1, ...store.subs.map((s) => s.sortIndex)) + 1 });
  store.subs.push(sub);
  await DB.put('subs', sub);
  $('#dlg-add').close();
  setScope({ type: 'sub', id: sub.id });
  syncAll({ only: sub });
}

function openEditSub(id) {
  const s = subById(id);
  const d = $('#dlg-edit');
  d.dataset.id = id;
  $('#edit-title').textContent = `r/${s.name}`;
  $('#edit-window').value = s.window;
  $('#edit-keywords').value = s.keywords.join(', ');
  $('#edit-enabled').checked = s.isEnabled;
  for (const k of Object.keys(KINDS)) $(`#edit-kind-${k}`).checked = s.includeKinds.includes(k);
  d.showModal();
}

async function submitEditSub(e) {
  e.preventDefault();
  const d = $('#dlg-edit');
  const s = subById(d.dataset.id);
  const oldWindow = s.window;
  s.window = $('#edit-window').value;
  s.keywords = splitList($('#edit-keywords').value);
  s.isEnabled = $('#edit-enabled').checked;
  s.includeKinds = Object.keys(KINDS).filter((k) => $(`#edit-kind-${k}`).checked);
  await DB.put('subs', s);
  await rescoreSubreddit(store, s);
  d.close();
  render();
  if (s.window !== oldWindow && s.isEnabled) syncAll({ only: s });
}

async function removeSub() {
  const d = $('#dlg-edit');
  const s = subById(d.dataset.id);
  if (!confirm(`Remove r/${s.name}? Its threads are deleted, except the ones you saved.`)) return;
  store.subs = store.subs.filter((x) => x !== s);
  const drop = [...store.threads.values()].filter((t) => t.sub === s.id && !t.isSaved).map((t) => t.id);
  for (const id of drop) store.threads.delete(id);
  await DB.delete('subs', s.id);
  await DB.delete('threads', drop);
  await DB.delete('details', drop);
  ui.searchDocs = null;
  d.close();
  setScope({ type: 'all' });
}

const splitList = (s) => [...new Set(s.split(/[,\n]/).map((x) => x.trim()).filter(Boolean))];

function openSettings() {
  const st = store.settings;
  for (const k of Object.keys(st.weights)) { $(`#w-${k}`).value = st.weights[k]; $(`#w-${k}-v`).textContent = Math.round(st.weights[k] * 100); }
  $('#set-keywords').value = st.boostKeywords.join(', ');
  $('#set-minup').value = st.minimumUpvotes;
  $('#set-hide').checked = st.hideImageAndMemePosts;
  $('#set-threads').value = st.threadsPerSubreddit;
  $('#set-comments').value = st.commentsPerThread;
  $('#set-interval').value = store.syncInterval;
  $('#dlg-settings').showModal();
}

async function submitSettings(e) {
  e.preventDefault();
  const st = store.settings;
  for (const k of Object.keys(st.weights)) st.weights[k] = +$(`#w-${k}`).value;
  st.boostKeywords = splitList($('#set-keywords').value);
  st.minimumUpvotes = Math.max(0, Math.round(+$('#set-minup').value || 0));
  st.hideImageAndMemePosts = $('#set-hide').checked;
  st.threadsPerSubreddit = +$('#set-threads').value;
  st.commentsPerThread = +$('#set-comments').value;
  store.syncInterval = $('#set-interval').value;
  await persistSettings();
  await rescoreAll(store);
  $('#dlg-settings').close();
  render();
}

async function eraseAll() {
  if (!confirm('Erase all threads, saved threads, subreddits and settings stored in this browser?')) return;
  await DB.clear();
  location.reload();
}

// MARK: Events

function wire() {
  document.addEventListener('click', (e) => {
    const t = e.target.closest('button, a');
    if (!t) return;
    if (t.classList.contains('row')) return select(t.dataset.id);
    if (t.classList.contains('side-item')) return setScope(t.dataset.scope === 'sub' ? { type: 'sub', id: t.dataset.id } : { type: t.dataset.scope });
    if (t.classList.contains('edit-sub')) return openEditSub(t.dataset.id);
    if (t.classList.contains('chip') && t.dataset.name) { $('#add-input').value = t.dataset.name; return $('#add-input').focus(); }
    switch (t.id || t.dataset.action) {
      case 'add-sub': return openAddSub();
      case 'sync': return syncAll({ full: true });
      case 'settings': return openSettings();
      case 'menu': return document.body.classList.toggle('drawer-open');
      case 'scrim': return document.body.classList.remove('drawer-open');
      case 'back': return select(null);
      case 'save': return toggleSave(ui.selected);
      case 'load-comments': return loadComments(ui.selected);
      case 'edit-remove': return removeSub();
      case 'erase': return eraseAll();
    }
    if (t.dataset.close != null) t.closest('dialog').close();
  });
  $('#scrim').addEventListener('click', () => document.body.classList.remove('drawer-open'));
  $('#form-add').addEventListener('submit', submitAddSub);
  $('#form-edit').addEventListener('submit', submitEditSub);
  $('#form-settings').addEventListener('submit', submitSettings);
  for (const k of Object.keys(DEFAULT_SETTINGS.weights)) $(`#w-${k}`).addEventListener('input', (e) => { $(`#w-${k}-v`).textContent = Math.round(e.target.value * 100); });
  $('#sort').addEventListener('change', (e) => { ui.sort = e.target.value; renderList(); });
  let searchTimer;
  $('#search').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { ui.query = e.target.value; renderList(); }, 120);
  });
  document.addEventListener('keydown', async (e) => {
    if (document.querySelector('dialog[open]')) return;
    const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName);
    if (e.key === '/' && !typing) { e.preventDefault(); return $('#search').focus(); }
    if (e.key === 'Escape' && typing && document.activeElement === $('#search') && $('#search').value) {
      $('#search').value = ''; ui.query = ''; return renderList();
    }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'j' || e.key === 'k' || e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const rows = [...document.querySelectorAll('.row')];
      if (!rows.length) return;
      e.preventDefault();
      const i = rows.findIndex((r) => r.dataset.id === ui.selected);
      const next = rows[Math.max(0, Math.min(rows.length - 1, i + (e.key === 'j' || e.key === 'ArrowDown' ? 1 : -1)))];
      select(next.dataset.id);
      next.scrollIntoView({ block: 'nearest' });
    }
    if (e.key === 's' && ui.selected) toggleSave(ui.selected);
  });
  setInterval(() => { maybeAutoSync(); if (!ui.syncing) renderSidebar(); }, 60e3);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) maybeAutoSync(); });
}

async function boot() {
  wire();
  try { await DB.init(); } catch {
    $('#threads').innerHTML = '<div class="empty"><h3>Storage is off</h3><p>Rounds keeps threads in this browser, and the browser refused. Private windows can do this.</p></div>';
    return;
  }
  const [subs, threads, settings, interval, lastSyncAll] = await Promise.all([
    DB.all('subs'), DB.all('threads'), DB.getKV('settings'), DB.getKV('syncInterval'), DB.getKV('lastSyncAll')]);
  store.settings = { ...structuredClone(DEFAULT_SETTINGS), ...(settings || {}) };
  store.settings.weights = { ...DEFAULT_SETTINGS.weights, ...(settings?.weights || {}) };
  store.syncInterval = interval || 'sixHours';
  store.lastSyncAll = lastSyncAll || 0;
  for (const t of threads) store.threads.set(t.id, t);
  const firstRun = !subs.length && !settings;
  store.subs = firstRun ? DEFAULT_SUBS.map((n, i) => newSubreddit(n, i)) : subs;
  if (firstRun) { await DB.put('subs', store.subs); await persistSettings(); }
  await render();
  Reddit.detect().then(() => { renderSidebar(); maybeAutoSync(); });
}

boot();
