// Read-only Reddit access. On the hosted launcher, /rounds/api/* is a server route that
// uses Reddit's OAuth API when REDDIT_CLIENT_ID is set there. Without it (or when this page
// runs on its own), Rounds reads Reddit's public JSON straight from the browser and falls back
// to the server route when Reddit refuses the browser.
'use strict';

const Reddit = (() => {
  let mode = null; // 'server' (OAuth on the server), 'hybrid' (browser first, then server), 'direct'

  async function detect() {
    if (mode) return mode;
    try {
      const r = await fetch('api/status', { headers: { accept: 'application/json' } });
      const j = r.ok && (r.headers.get('content-type') || '').includes('json') ? await r.json() : null;
      mode = j && j.rounds ? (j.oauth ? 'server' : 'hybrid') : 'direct';
    } catch { mode = 'direct'; }
    return mode;
  }

  class RedditError extends Error {
    constructor(message, status) { super(message); this.status = status; }
  }

  const PATHS = {
    top: (p) => [`/r/${p.sub}/top.json`, { t: p.t, limit: p.limit, after: p.after }],
    hot: (p) => [`/r/${p.sub}/hot.json`, { limit: p.limit }],
    comments: (p) => [`/comments/${p.id}.json`, { limit: p.limit, sort: 'top' }],
    about: (p) => [`/r/${p.sub}/about.json`, {}],
  };
  const qs = (o) => new URLSearchParams(Object.entries(o).filter(([, v]) => v != null && v !== '')).toString();

  function errorFor(status, route, p, body) {
    if (status === 404) return new RedditError(route === 'comments' ? 'That thread is gone.' : `r/${p.sub} doesn't exist.`, 404);
    if (status === 403) {
      const reason = body?.reason;
      if (reason === 'quarantined') return new RedditError(`r/${p.sub} is quarantined.`, 403);
      if (reason === 'banned') return new RedditError(`r/${p.sub} is banned.`, 403);
      return new RedditError(body?.error && typeof body.error === 'string' ? body.error : `Reddit refused the request (r/${p.sub || p.id} may be private).`, 403);
    }
    if (status === 429) return new RedditError('Reddit is rate-limiting requests. Try again in a minute.', 429);
    return new RedditError(body?.error && typeof body.error === 'string' ? body.error : `Reddit returned an error (${status}).`, status);
  }

  async function direct(route, p) {
    const [path, q] = PATHS[route](p);
    const r = await fetch(`https://www.reddit.com${path}?${qs(q)}`, { credentials: 'omit' });
    const body = await r.json().catch(() => null);
    if (!r.ok) throw errorFor(r.status, route, p, body);
    return body;
  }

  async function server(route, p) {
    const r = await fetch(`api/${route}?${qs(p)}`, { headers: { accept: 'application/json' } });
    const body = await r.json().catch(() => null);
    if (!r.ok) throw errorFor(r.status, route, p, body);
    return body;
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  async function get(route, p) {
    const m = await detect();
    for (let attempt = 0; ; attempt++) {
      try {
        if (m === 'server') return await server(route, p);
        if (m === 'direct') return await direct(route, p);
        try { return await direct(route, p); } catch (e) {
          if (e.status === 404) throw e;
          return await server(route, p); // CORS failures and 403/429 from the browser
        }
      } catch (e) {
        if ((e.status === 429 || e.status >= 500) && attempt < 2) { await sleep(1500 * (attempt + 1)); continue; }
        if (e instanceof RedditError) throw e;
        throw new RedditError("Couldn't reach Reddit. Check your connection.", 0);
      }
    }
  }

  return {
    detect,
    get mode() { return mode; },
    top: (sub, t, limit, after) => get('top', { sub, t, limit, after }).then(parseListing),
    hot: (sub, limit) => get('hot', { sub, limit }).then(parseListing),
    comments: (id, limit) => get('comments', { id, limit }).then(parseComments),
    about: (sub) => get('about', { sub }).then((j) => {
      if (j?.kind !== 't5') throw new RedditError(`r/${sub} doesn't exist.`, 404);
      const d = j.data || {};
      return { name: d.display_name, type: d.subreddit_type, subscribers: d.subscribers, description: d.public_description, quarantine: !!d.quarantine };
    }),
  };
})();
