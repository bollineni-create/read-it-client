// Rounds core: a port of RoundsCore (Swift) to plain JS. Scoring, link extraction,
// thread classification, subreddit-name parsing and building thread records from Reddit JSON.
'use strict';

const TIME_WINDOWS = {
  week: { label: 'Past week', phrase: 'this week' },
  month: { label: 'Past month', phrase: 'this month' },
  year: { label: 'Past year', phrase: 'this year' },
  all: { label: 'All time', phrase: 'of all time' },
};
const KINDS = { discussion: 'Discussion', question: 'Question', resource: 'Resource' };

const DEFAULT_SUBS = ['mdphd', 'medicalschool', 'medicine', 'medschool', 'mcat'];
const SUGGESTED_SUBS = ['premed', 'Residency', 'step1', 'USMLE'];
const PALETTE = ['#0B6E69', '#D9822B', '#5B5BD6', '#C2410C', '#0E7490', '#9D174D', '#4D7C0F', '#7C3AED', '#B45309', '#2563EB'];
const colorForIndex = (i) => PALETTE[((i % PALETTE.length) + PALETTE.length) % PALETTE.length];

const DEFAULT_SETTINGS = {
  weights: { upvotes: 0.35, discussion: 0.25, resources: 0.2, keywords: 0.2 },
  boostKeywords: ['MSTP', 'interviews', 'Anki', 'research', 'match'],
  hideImageAndMemePosts: true,
  minimumUpvotes: 25,
  // The web version syncs from the browser, so it keeps fewer threads than the Mac app's 250.
  threadsPerSubreddit: 100,
  commentsPerThread: 20, // 0 = all
};
const THREAD_LIMIT_CHOICES = [100, 250, 1000];
const COMMENT_LIMIT_CHOICES = [10, 20, 0];

function newSubreddit(name, index, extra = {}) {
  return {
    id: name.toLowerCase(), name, colorHex: colorForIndex(index), window: 'month', keywords: [],
    includeKinds: Object.keys(KINDS), lastSynced: null, lastError: null, isEnabled: true, sortIndex: index, ...extra,
  };
}

// MARK: HTML entities

const ENTITIES = [['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&#39;', "'"], ['&#x27;', "'"],
  ['&nbsp;', ' '], ['&#x200B;', ''], ['&#8203;', ''], ['&amp;', '&']];
function decodeEntities(s) {
  if (!s || !s.includes('&')) return s || '';
  for (const [e, r] of ENTITIES) s = s.split(e).join(r);
  return s;
}

// MARK: Links

const TRACKING = new Set(['fbclid', 'gclid', 'dclid', 'gbraid', 'wbraid', 'msclkid', 'yclid', 'twclid', 'igshid', 'igsh',
  'mc_cid', 'mc_eid', '_hsenc', '_hsmi', 'mkt_tok', 'ref', 'ref_src', 'ref_url', 'referrer',
  'si', 'spm', 'share_id', 'trk', 'trkinfo', 'oly_anon_id', 'oly_enc_id', 'vero_id', 'rb_clickid',
  's_cid', 'cmpid', 'src', 'feature', 'ved', 'ei', 'sca_esv', '_ga', '_gl', 'context']);
const REDDIT_HOSTS = ['reddit.com', 'redd.it', 'redditmedia.com', 'redditstatic.com', 'reddituploads.com'];
const IMAGE_HOSTS = ['i.redd.it', 'v.redd.it', 'preview.redd.it', 'i.imgur.com', 'imgur.com', 'gfycat.com', 'giphy.com', 'media.giphy.com'];
const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'gifv', 'webp', 'mp4', 'heic'];
const MD_LINK = /\[([^\]\n]{0,300})\]\(\s*<?(https?:\/\/[^\s)>]+(?:\([^\s)]*\)[^\s)>]*)*)>?(?:\s+"[^"]*")?\s*\)/gi;
const BARE_URL = /https?:\/\/[^\s<>\[\]"'`|]+/gi;

const hostMatches = (host, list) => list.some((h) => host === h || host.endsWith('.' + h));
const pathExt = (path) => { const last = path.split('/').pop() || ''; const i = last.lastIndexOf('.'); return i > 0 ? last.slice(i + 1).toLowerCase() : ''; };

function parseURL(s) { try { return new URL(s); } catch { return null; } }

function isRedditURL(url) {
  const u = parseURL(url);
  return !!u && hostMatches(u.hostname.toLowerCase(), REDDIT_HOSTS);
}

function isImageHost(url) {
  const u = parseURL(url);
  if (!u) return false;
  if (IMAGE_HOSTS.includes(u.hostname.toLowerCase())) return true;
  return IMAGE_EXT.includes(pathExt(u.pathname));
}

function redirectTarget(host, u) {
  const q = (n) => u.searchParams.get(n);
  switch (host) {
    case 'google.com': case 'www.google.com': return u.pathname === '/url' ? (q('q') || q('url')) : null;
    case 'out.reddit.com': return q('url');
    case 'l.facebook.com': case 'lm.facebook.com': return q('u');
    case 'youtube.com': case 'www.youtube.com': return u.pathname === '/redirect' ? q('q') : null;
    default: return null;
  }
}

function normalizeURL(raw, depth = 0) {
  const cleaned = raw.trim().replace(/\\_/g, '_').replace(/\\\(/g, '(').replace(/\\\)/g, ')').replace(/\\~/g, '~');
  const u = parseURL(cleaned);
  if (!u || (u.protocol !== 'http:' && u.protocol !== 'https:')) return null;
  let host = u.hostname.toLowerCase();
  if (!host || !host.includes('.')) return null;
  const target = depth < 3 ? redirectTarget(host, u) : null;
  if (target && target !== raw) return normalizeURL(target, depth + 1);
  if (host.startsWith('www.')) host = host.slice(4);
  if (host.startsWith('m.') && host !== 'm.me') host = host.slice(2);
  u.hostname = host;
  u.hash = '';
  for (const name of [...u.searchParams.keys()]) {
    const n = name.toLowerCase();
    if (n.startsWith('utm_') || TRACKING.has(n)) u.searchParams.delete(name);
  }
  let path = u.pathname;
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  const query = u.searchParams.toString();
  const port = u.port ? ':' + u.port : '';
  const url = `${u.protocol}//${host}${port}${path === '/' ? '' : path}${query ? '?' + query : ''}`;
  return { url, domain: host };
}

function trimTrailing(url) {
  let s = url;
  while (s.length) {
    const last = s[s.length - 1];
    if ('.,;:!?*\'"'.includes(last) || last === '\\') s = s.slice(0, -1);
    else if (last === ')') {
      const opens = (s.match(/\(/g) || []).length, closes = (s.match(/\)/g) || []).length;
      if (closes > opens) s = s.slice(0, -1); else break;
    } else break;
  }
  return s;
}

function displayTitle(mdTitle, url, domain) {
  const t = (mdTitle || '').trim();
  if (t && normalizeURL(t)?.url !== url && !t.toLowerCase().startsWith('http')) return t;
  const u = parseURL(url);
  if (u) {
    const last = u.pathname.split('/').filter(Boolean).pop() || '';
    let decoded = last;
    try { decoded = decodeURIComponent(last); } catch {}
    const dot = decoded.lastIndexOf('.');
    const stem = dot > 0 ? decoded.slice(0, dot) : decoded;
    const ext = dot > 0 ? decoded.slice(dot + 1) : '';
    const pretty = stem.replace(/[-_]/g, ' ');
    const opaque = pretty.length > 24 && !pretty.includes(' ');
    if (pretty && !opaque && /\p{L}/u.test(pretty)) return ext ? `${pretty}.${ext}` : pretty;
  }
  return domain;
}

/** Unique, normalized external links in order of first appearance. */
function extractLinks(markdown) {
  const text = decodeEntities(markdown || '');
  const found = [];
  for (const m of text.matchAll(MD_LINK)) found.push({ start: m.index, end: m.index + m[0].length, url: m[2], title: m[1] });
  const mdRanges = found.slice();
  for (const m of text.matchAll(BARE_URL)) {
    const start = m.index, end = start + m[0].length;
    if (mdRanges.some((r) => start < r.end && end > r.start)) continue;
    found.push({ start, end, url: trimTrailing(m[0]), title: null });
  }
  found.sort((a, b) => a.start - b.start);
  const seen = new Set(), out = [];
  for (const f of found) {
    const n = normalizeURL(f.url);
    if (!n || isRedditURL(n.url) || seen.has(n.url)) continue;
    seen.add(n.url);
    out.push({ url: n.url, domain: n.domain, title: displayTitle(f.title, n.url, n.domain) });
  }
  return out;
}

// MARK: Classification

const FILE_EXT = new Set(['pdf', 'xlsx', 'xls', 'csv', 'doc', 'docx', 'ppt', 'pptx', 'key', 'apkg', 'zip', 'numbers', 'pages']);
const RESOURCE_HOSTS = ['docs.google.com', 'drive.google.com', 'sheets.google.com', 'dropbox.com', 'onedrive.live.com',
  '1drv.ms', 'box.com', 'notion.so', 'notion.site', 'ankiweb.net', 'github.com', 'quizlet.com'];
const RESOURCE_TERMS = ['anki', 'deck', 'spreadsheet', 'google sheet', 'template', 'pdf', 'resource', 'resources',
  'cheat sheet', 'cheatsheet', 'study guide', 'flashcards', 'notes i made', 'free notes'];
const QUESTION_STARTERS = new Set(['how', 'what', 'why', 'when', 'where', 'who', 'whom', 'which', 'whose',
  'should', 'is', 'are', 'am', 'was', 'were', 'can', 'could', 'would', 'will', 'do', 'does', 'did',
  'has', 'have', 'had', 'any', 'anyone', 'anybody', 'thoughts', 'advice', 'help']);

function containsWord(haystack, needle) {
  let from = 0, i;
  while ((i = haystack.indexOf(needle, from)) !== -1) {
    const before = i === 0 || !/\p{L}/u.test(haystack[i - 1]);
    const j = i + needle.length;
    const after = j >= haystack.length || !/\p{L}/u.test(haystack[j]);
    if (before && after) return true;
    from = j;
  }
  return false;
}

function isQuestion(title) {
  const t = title.trim();
  if (t.endsWith('?') || t.includes('? ')) return true;
  const words = t.toLowerCase().split(/[^\p{L}']+/u).filter(Boolean);
  if (!words.length) return false;
  return QUESTION_STARTERS.has(words[0]) && words.length >= 3;
}

function classify(title, postLinks) {
  const shareable = postLinks.filter((l) => !isImageHost(l.url));
  const hostOrFile = shareable.some((l) => hostMatches(l.domain, RESOURCE_HOSTS) || FILE_EXT.has(pathExt(parseURL(l.url)?.pathname || '')));
  if (hostOrFile) return 'resource';
  const lower = title.toLowerCase();
  if (RESOURCE_TERMS.some((term) => containsWord(lower, term)) && !isQuestion(title)) return 'resource';
  if (shareable.length >= 2) return 'resource';
  return isQuestion(title) ? 'question' : 'discussion';
}

// MARK: Subreddit names

const NAME_ERRORS = {
  empty: 'Enter a subreddit name.',
  notURL: "That link doesn't point to a subreddit.",
  short: 'Subreddit names are at least 3 characters.',
  long: 'Subreddit names are at most 21 characters.',
  chars: 'Use only letters, numbers and underscores.',
};

/** Returns { name } or { error }. Accepts name, r/name, /r/name and reddit URLs. */
function parseSubredditName(raw, existing = []) {
  let input = (raw || '').trim();
  if (!input) return { error: NAME_ERRORS.empty };
  const lower = input.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://') || lower.includes('reddit.com/') || lower.startsWith('redd.it/')) {
    const u = parseURL(lower.startsWith('http') ? input : 'https://' + input);
    const host = u?.hostname.toLowerCase();
    if (!u || !(host === 'reddit.com' || host.endsWith('.reddit.com'))) return { error: NAME_ERRORS.notURL };
    const parts = u.pathname.split('/').filter(Boolean);
    if (parts.length < 2 || parts[0].toLowerCase() !== 'r') return { error: NAME_ERRORS.notURL };
    input = parts[1];
  } else {
    if (input.startsWith('/')) input = input.slice(1);
    if (input.toLowerCase().startsWith('r/')) input = input.slice(2);
    if (input.endsWith('/')) input = input.slice(0, -1);
  }
  if (!input) return { error: NAME_ERRORS.empty };
  if (!/^[A-Za-z0-9_]+$/.test(input)) return { error: NAME_ERRORS.chars };
  if (input.length < 3) return { error: NAME_ERRORS.short };
  if (input.length > 21) return { error: NAME_ERRORS.long };
  if (existing.some((e) => e.toLowerCase() === input.toLowerCase())) return { error: `r/${input} is already in your list.` };
  return { name: input };
}

// MARK: Reddit JSON

function parsePost(d) {
  return {
    id: d.id, subreddit: d.subreddit, title: decodeEntities(d.title || ''), selftext: decodeEntities(d.selftext || ''),
    author: d.author || '[deleted]', score: d.score || 0, numComments: d.num_comments || 0, createdUTC: d.created_utc || 0,
    permalink: d.permalink || `/comments/${d.id}`, url: d.url ? decodeEntities(d.url) : null, postHint: d.post_hint || null,
    isSelf: !!d.is_self, isGallery: !!d.is_gallery, isVideo: !!d.is_video, flair: d.link_flair_text || null,
    stickied: !!d.stickied, over18: !!d.over_18,
  };
}

/** Posts of a listing (`t3` children only). */
function parseListing(json) {
  const data = json?.data || {};
  return { after: data.after || null, posts: (data.children || []).filter((c) => c.kind === 't3' && c.data).map((c) => parsePost(c.data)) };
}

function parseCommentNode(d) {
  const replies = d.replies && typeof d.replies === 'object'
    ? (d.replies.data?.children || []).filter((c) => c.kind === 't1').map((c) => parseCommentNode(c.data)) : [];
  return { id: d.id, author: d.author || '[deleted]', body: decodeEntities(d.body || ''), score: d.score || 0, depth: d.depth || 0, replies };
}

/** `/comments/{id}` returns [postListing, commentListing]. */
function parseComments(json) {
  const post = Array.isArray(json) ? parseListing(json[0]).posts[0] || null : null;
  const tree = Array.isArray(json) ? (json[1]?.data?.children || []).filter((c) => c.kind === 't1').map((c) => parseCommentNode(c.data)) : [];
  return { post, tree };
}

const flatten = (node) => [node, ...node.replies.flatMap(flatten)];

function isImageOrMeme(p) {
  const flair = (p.flair || '').toLowerCase();
  if (['meme', 'humor', 'humour', 'shitpost', 'funny'].some((w) => flair.includes(w)) || containsWord(p.title.toLowerCase(), 'meme')) return true;
  if (p.selftext.trim()) return false;
  if (p.isGallery || p.isVideo) return true;
  if (['image', 'hosted:video', 'rich:video'].includes(p.postHint)) return true;
  return !p.isSelf && !!p.url && isImageHost(p.url);
}

const externalURL = (p) => (!p.isSelf && p.url && p.url.startsWith('http') && !isRedditURL(p.url) ? p.url : null);

/**
 * Builds a thread record, its comments and resources. `limit` null keeps every comment;
 * `tree` empty with limit 0 means a counters-only refresh.
 */
function buildThread(post, subID, tree, limit, existing) {
  let flat = tree.flatMap(flatten).filter((c) => c.body !== '[deleted]' && c.body !== '[removed]');
  if (limit != null) flat = flat.slice(0, limit);
  const comments = flat.map((c, i) => ({ id: c.id, author: c.author, body: c.body, score: c.score, depth: c.depth, position: i }));

  let postLinks = [];
  const ext = externalURL(post);
  if (ext && !isImageHost(ext)) postLinks = postLinks.concat(extractLinks(ext));
  postLinks = postLinks.concat(extractLinks(post.selftext));
  const seen = new Set(), resources = [];
  for (const l of postLinks) if (!seen.has(l.url)) { seen.add(l.url); resources.push({ ...l, sourceCommentId: null }); }
  for (const c of flat) for (const l of extractLinks(c.body)) if (!seen.has(l.url)) { seen.add(l.url); resources.push({ ...l, sourceCommentId: c.id }); }

  const now = Date.now();
  const thread = {
    id: post.id, sub: subID, subName: post.subreddit, title: post.title, body: post.selftext, author: post.author,
    score: post.score, numComments: post.numComments, createdUTC: post.createdUTC * 1000, permalink: post.permalink,
    postURL: ext || post.url, kind: classify(post.title, postLinks),
    relevance: existing?.relevance ?? 0, why: existing?.why ?? '', matchedKeywords: existing?.matchedKeywords ?? [],
    isSaved: existing?.isSaved ?? false, savedOnReddit: existing?.savedOnReddit ?? false, linkCount: resources.length,
    maxDepth: comments.reduce((m, c) => Math.max(m, c.depth), 0), isImageOnly: isImageOrMeme(post),
    commentsFetchedAt: !tree.length && limit === 0 ? existing?.commentsFetchedAt ?? null : now,
    firstSeenAt: existing?.firstSeenAt ?? now, updatedAt: now,
  };
  return { thread, comments, resources };
}

// MARK: Scoring

const logNorm = (v, max) => { v = Math.max(v, 0); const m = Math.max(max, v, 0); return m > 0 ? Math.log1p(v) / Math.log1p(m) : 0; };
const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function matchKeywords(keywords, texts) {
  const hay = texts.join('\n'), seen = new Set(), out = [];
  for (const raw of keywords) {
    const k = (raw || '').trim();
    if (!k || seen.has(k.toLowerCase())) continue;
    seen.add(k.toLowerCase());
    if (new RegExp(`(?<![\\p{L}\\p{N}])${escapeRegex(k)}(?![\\p{L}\\p{N}])`, 'iu').test(hay)) out.push(k);
  }
  return out;
}

function compact(n) {
  if (n >= 10000) return `${Math.round(n / 1000)}k`;
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

function scoreThread(t, commentBodies, sub, stats, weights, keywords) {
  const up = logNorm(t.score, stats.maxScore);
  const comments = logNorm(t.numComments, stats.maxComments);
  const depth = Math.min(Math.max(t.maxDepth, 0), 5) / 5;
  const discussion = 0.7 * comments + 0.3 * depth;
  const resources = Math.min(t.linkCount, 4) / 4;
  const matched = matchKeywords(keywords, [t.title, t.body, ...commentBodies]);
  const kw = matched.length ? 1 - Math.pow(0.4, matched.length) : 0;
  const w = Object.fromEntries(['upvotes', 'discussion', 'resources', 'keywords'].map((k) => [k, Math.max(+weights[k] || 0, 0)]));
  const total = w.upvotes + w.discussion + w.resources + w.keywords;
  const weighted = total > 0 ? (w.upvotes * up + w.discussion * discussion + w.resources * resources + w.keywords * kw) / total : 0;
  const relevance = Math.round(Math.min(Math.max(weighted, 0), 1) * 1000) / 10;

  const subName = `r/${sub?.name || t.subName}`;
  const phrase = TIME_WINDOWS[sub?.window || 'month'].phrase;
  const ranked = [['upvotes', w.upvotes * up], ['discussion', w.discussion * discussion], ['resources', w.resources * resources]]
    .filter((x) => x[1] > 0.0001).sort((a, b) => b[1] - a[1]);
  const parts = [];
  if (ranked.length) {
    const lead = ranked[0];
    if (lead[0] === 'upvotes') parts.push(`Top post in ${subName} ${phrase}`);
    else if (lead[0] === 'discussion') parts.push(`Top discussion in ${subName} ${phrase}`);
    else parts.push(t.linkCount === 1 ? `Shares a resource in ${subName}` : `Shares ${t.linkCount} resources in ${subName}`);
    if (ranked.length > 1 && ranked[1][1] >= lead[1] * 0.6) {
      const s = ranked[1][0];
      if (s === 'upvotes') parts.push(`${compact(t.score)} upvotes`);
      else if (s === 'discussion') parts.push(`${compact(t.numComments)} comments`);
      else if (t.linkCount > 0) parts.push(t.linkCount === 1 ? '1 link shared' : `${t.linkCount} links shared`);
    }
  } else if (!matched.length) parts.push(`New in ${subName}`);
  if (matched.length) parts.push('matches: ' + matched.slice(0, 4).join(', '));
  return { relevance, why: parts.join(' · '), matchedKeywords: matched };
}

// MARK: Search

const tokenize = (s) => (s || '').toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
const searchTerms = (q) => tokenize(q);

/**
 * BM25 over title (10), body (4), comments (1) and resources (2), like the Mac app's FTS5 ranking.
 * Every term must match, as a prefix. Returns a Map of thread id → score (higher is better).
 */
function searchScores(docs, query) {
  const terms = searchTerms(query);
  if (!terms.length) return null;
  const fields = [['title', 10], ['body', 4], ['comments', 1], ['resources', 2]];
  const avg = {};
  for (const [f] of fields) avg[f] = docs.reduce((s, d) => s + d.tokens[f].length, 0) / Math.max(docs.length, 1) || 1;
  const N = docs.length, k1 = 1.2, b = 0.75;
  const df = terms.map((term) => docs.filter((d) => fields.some(([f]) => d.tokens[f].some((t) => t.startsWith(term)))).length);
  const out = new Map();
  for (const d of docs) {
    let score = 0, ok = true;
    terms.forEach((term, i) => {
      let termScore = 0;
      for (const [f, weight] of fields) {
        const toks = d.tokens[f];
        let tf = 0;
        for (const t of toks) if (t.startsWith(term)) tf++;
        if (!tf) continue;
        const idf = Math.log((N - df[i] + 0.5) / (df[i] + 0.5) + 1);
        termScore += weight * idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * toks.length / avg[f]));
      }
      if (!termScore) ok = false;
      score += termScore;
    });
    if (ok) out.set(d.id, score);
  }
  return out;
}

// MARK: Formatting

function shortAge(ms, now = Date.now()) {
  const s = Math.max(0, (now - ms) / 1000);
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 30 * 86400) return `${Math.floor(s / 86400)}d`;
  if (s < 365 * 86400) return `${Math.floor(s / (30 * 86400))}mo`;
  return `${Math.floor(s / (365 * 86400))}y`;
}

if (typeof module !== 'undefined') {
  module.exports = { extractLinks, normalizeURL, classify, isQuestion, parseSubredditName, parseListing, parseComments,
    buildThread, scoreThread, matchKeywords, searchScores, tokenize, isImageOrMeme, compact, shortAge, decodeEntities };
}
