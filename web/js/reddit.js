// Read-only Reddit access. On the hosted launcher, /rounds/api/* is a server route. It uses
// Reddit's OAuth API when REDDIT_CLIENT_ID is set there, and Reddit's public feeds when it
// isn't. Feeds carry no upvote or comment counts and no reply tree: posts come back with a
// score of -1 and are ranked by their place in the top listing instead (see core.js).
// When this page runs on its own, with no server route, it asks Reddit straight from the browser.
'use strict';

const Reddit = (() => {
  let mode = null; // 'server' (the route answers everything), 'hybrid' (browser first, then the route), 'direct'
  let feeds = false; // the route reads feeds: no counts, and Reddit allows only a few requests a minute

  async function detect() {
    if (mode) return mode;
    try {
      const r = await fetch('api/status', { headers: { accept: 'application/json' } });
      const j = r.ok && (r.headers.get('content-type') || '').includes('json') ? await r.json() : null;
      feeds = !!(j && j.rounds && j.feeds);
      mode = j && j.rounds ? (j.oauth || j.feeds ? 'server' : 'hybrid') : 'direct';
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

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // MARK: Feeds
  //
  // Reddit allows an address about one feed request a minute, and says so on every answer: how
  // many requests are left and the seconds until that refills. The server route passes both on
  // (X-Reddit-Remaining, X-Reddit-Reset; Retry-After on a 429). Like the Mac app's RateLimiter,
  // the page keeps to that budget: requests go out one at a time and wait for Reddit to be ready.
  // The site keeps answers at its edge for hours and shares them between visitors, and an answer
  // from there costs Reddit nothing. So while the page would have to wait, it first asks for the
  // answer "only if the edge has it" (X-Rounds-Cached-Only), and waits only when it doesn't.
  const MIN_SPACING = 1000;
  const MARGIN = 500; // past the moment Reddit says its budget refills
  const MAX_RETRIES = 4;
  const BACKOFF = 5000; // doubled on each retry when Reddit gives no time to wait
  const LONGEST_WAIT = 90000;
  const budget = { remaining: null, resetAt: 0, lastAt: 0, pausedUntil: 0 };
  let feedQueue = Promise.resolve();
  let onWait = () => {};

  const num = (v) => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
  const fromEdge = (r) => ['HIT', 'STALE', 'REVALIDATED'].includes(r.headers.get('x-vercel-cache'));

  /** Milliseconds until Reddit will take another request, as far as the page knows. */
  function waitForReddit(now = Date.now()) {
    let at = Math.max(now, budget.lastAt + MIN_SPACING, budget.pausedUntil);
    if (budget.remaining != null && budget.resetAt > now) {
      if (budget.remaining < 1) at = Math.max(at, budget.resetAt);
      // Spread what's left of the budget over the time left before it refills.
      else at = Math.max(at, budget.lastAt + (budget.resetAt - now) / budget.remaining);
    }
    return at - now;
  }

  /** What an answer that came from Reddit just now says about the budget. */
  function learnBudget(r, now = Date.now()) {
    if (fromEdge(r)) return;
    budget.lastAt = now;
    const remaining = num(r.headers.get('x-reddit-remaining'));
    const reset = num(r.headers.get('x-reddit-reset'));
    if (remaining != null) budget.remaining = remaining;
    if (reset != null) budget.resetAt = now + reset * 1000 + MARGIN;
  }

  async function feedRequest(url) {
    const headers = { accept: 'application/json' };
    for (let attempt = 0; ; attempt++) {
      let wait = waitForReddit();
      if (wait > MIN_SPACING) {
        const held = await fetch(url, { headers: { ...headers, 'x-rounds-cached-only': '1' } }).catch(() => null);
        if (held && held.status === 200) return held;
        wait = waitForReddit();
      }
      if (wait > 0) {
        onWait(wait);
        await sleep(wait);
        onWait(0);
      }
      const r = await fetch(url, { headers });
      learnBudget(r);
      if ((r.status !== 429 && r.status < 500) || attempt >= MAX_RETRIES) return r;
      const told = num(r.headers.get('retry-after')) ?? num(r.headers.get('x-reddit-reset'));
      budget.pausedUntil = Date.now() + Math.min(told != null ? told * 1000 + MARGIN : BACKOFF * 2 ** attempt, LONGEST_WAIT);
    }
  }

  /** Feed requests queue, so a sync and a "Load comments" tap at the same moment still go out in turn. */
  function inTurn(url) {
    const turn = feedQueue.then(() => feedRequest(url));
    feedQueue = turn.catch(() => {});
    return turn;
  }

  async function server(route, p) {
    const url = `api/${route}?${qs(p)}`;
    const r = await (feeds ? inTurn(url) : fetch(url, { headers: { accept: 'application/json' } }));
    const body = await r.json().catch(() => null);
    if (!r.ok) throw errorFor(r.status, route, p, body);
    return body;
  }

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
        // A feed request has already waited and retried on Reddit's own schedule.
        if (!feeds && (e.status === 429 || e.status >= 500) && attempt < 2) { await sleep(1500 * (attempt + 1)); continue; }
        if (e instanceof RedditError) throw e;
        throw new RedditError("Couldn't reach Reddit. Check your connection.", 0);
      }
    }
  }

  return {
    detect,
    get mode() { return mode; },
    get feeds() { return feeds; },
    /** Called with the milliseconds a feed request is about to wait for Reddit, then with 0 when it goes. */
    set onWait(fn) { onWait = typeof fn === 'function' ? fn : () => {}; },
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
