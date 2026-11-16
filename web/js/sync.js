// Sync, ported from the Mac app's SyncEngine: fetch top (and hot) posts per subreddit,
// fetch comments where they changed, rebuild resources, rescore and prune.
//
// The work is ordered so the page is useful as early as possible, which matters when Reddit
// allows only about one request a minute (see reddit.js): first every subreddit's top posts,
// then what's hot, and only then comments, a thread at a time across the subreddits.
'use strict';

// A sync fetches comments for at most this many threads per subreddit; later syncs pick up the rest.
const COMMENT_FETCHES_PER_SUB = 30;
const DAY = 86400e3;
const RATE_LIMITED = 'Reddit is rate-limiting requests. The remaining comments will load on the next sync.';

/** Stores posts from a listing as threads, keeping what earlier comment fetches found. */
async function storePosts(store, sub, posts, ranks) {
  for (const post of posts) {
    const old = store.threads.get(post.id);
    const built = buildThread(post, sub.id, [], 0, old, ranks.get(post.id) ?? null);
    if (old) {
      built.thread.linkCount = Math.max(built.thread.linkCount, old.linkCount);
      built.thread.maxDepth = old.maxDepth;
      if (old.kind === 'resource') built.thread.kind = 'resource';
    } else {
      await DB.put('details', { id: post.id, comments: [], resources: built.resources });
    }
    store.threads.set(post.id, built.thread);
  }
}

/**
 * Step 1 for one subreddit: its top posts. A post's place in the listing becomes its rank, which
 * stands in for the score feeds don't carry. Returns the plan the later steps work from.
 */
async function syncTop(store, sub) {
  const keep = store.settings.threadsPerSubreddit;
  const plan = { posts: [], seen: new Set(), ranks: new Map() };
  try {
    let after = null;
    do {
      const page = await Reddit.top(sub.name, sub.window, Math.min(100, keep - plan.posts.length), after);
      for (const p of page.posts) if (!plan.seen.has(p.id)) { plan.seen.add(p.id); plan.posts.push(p); plan.ranks.set(p.id, plan.posts.length); }
      after = page.after;
      if (!page.posts.length) break;
    } while (after && plan.posts.length < keep);

    const canonical = plan.posts[0]?.subreddit;
    if (canonical && canonical !== sub.name && canonical.toLowerCase() === sub.id) sub.name = canonical;

    await storePosts(store, sub, plan.posts, plan.ranks);
    // A thread that has dropped out of the top listing no longer has a place in it.
    for (const t of store.threads.values()) if (t.sub === sub.id && !plan.ranks.has(t.id)) t.topRank = null;
    await rescoreSubreddit(store, sub);
    sub.lastSynced = Date.now();
    sub.lastError = null;
    return plan;
  } catch (e) {
    sub.lastError = e.message || String(e);
    throw e;
  } finally {
    await DB.put('subs', sub);
  }
}

/** Step 2: what's hot, for threads too new to be among the top posts. A subreddit is still synced without it. */
async function syncHot(store, sub, plan) {
  let hot;
  try { hot = await Reddit.hot(sub.name, 50); } catch { return false; }
  const fresh = hot.posts.filter((p) => !p.stickied && !plan.seen.has(p.id));
  for (const p of fresh) { plan.seen.add(p.id); plan.posts.push(p); }
  await storePosts(store, sub, fresh, plan.ranks);
  await rescoreSubreddit(store, sub);
  await prune(store, sub, store.settings.threadsPerSubreddit);
  return true;
}

/** The threads of a plan that need their comments fetched, best first. */
function commentQueue(store, plan, full) {
  const { minimumUpvotes: minUp, hideImageAndMemePosts: hide } = store.settings;
  const rankOf = (p) => plan.ranks.get(p.id) ?? Infinity;
  const now = Date.now();
  const fetched = (p) => !!store.threads.get(p.id)?.commentsFetchedAt;
  const queue = [...plan.posts]
    .sort((a, b) => b.score - a.score || (rankOf(a) === rankOf(b) ? 0 : rankOf(a) - rankOf(b)))
    .filter((post) => {
      const old = store.threads.get(post.id);
      if (!old) return false; // pruned
      const lowScore = post.score >= 0 && post.score < minUp;
      if ((lowScore || (hide && isImageOrMeme(post))) && !(old.isSaved || old.savedOnReddit)) return false;
      if (!old.commentsFetchedAt) return true;
      if (full && now - old.commentsFetchedAt > DAY) return true; // a full pass also refreshes day-old comments
      // Feeds don't say how many comments a thread has, so only age triggers a refresh there.
      return post.numComments >= 0 && old.numComments !== post.numComments;
    });
  // Threads never fetched go first, so a capped pass fills gaps before it refreshes.
  return [...queue.filter((p) => !fetched(p)), ...queue.filter(fetched)].slice(0, COMMENT_FETCHES_PER_SUB);
}

/** Step 3 for one thread. Throws only when Reddit is rate-limiting; any other failure skips the thread. */
async function syncThreadComments(store, sub, post, plan) {
  const settings = store.settings;
  try {
    const res = await Reddit.comments(post.id, settings.commentsPerThread || 500);
    const old = store.threads.get(post.id);
    if (!old) return false;
    const built = buildThread(res.post || post, sub.id, res.tree, settings.commentsPerThread || null, old, plan.ranks.get(post.id) ?? old.topRank ?? null);
    await DB.put('details', { id: post.id, comments: built.comments, resources: built.resources });
    await DB.put('threads', built.thread);
    store.threads.set(post.id, built.thread);
    return true;
  } catch (e) {
    if (e.status === 429) throw e;
    return false;
  }
}

/**
 * Syncs subreddits in three steps. `onListed` is called whenever the list has new threads to show,
 * `onComments(done, total)` as comments come in, and `alive()` returning false stops the work
 * (a newer sync has started). Resolves once the listings are in, with how many subreddits were
 * listed; the comments keep loading, and the `comments` promise it returns settles when they are in.
 */
async function syncSubreddits(store, subs, { full = false, onProgress = () => {}, onListed = () => {}, onComments = () => {}, alive = () => true } = {}) {
  const plans = new Map();
  for (const sub of subs) {
    if (!alive()) break;
    onProgress(`Fetching r/${sub.name}…`);
    try { plans.set(sub, await syncTop(store, sub)); } catch (e) { console.warn(`r/${sub.name}:`, e.message); }
    onListed();
  }
  for (const [sub, plan] of plans) {
    if (!alive()) break;
    onProgress(`Fetching what’s hot in r/${sub.name}…`);
    if (await syncHot(store, sub, plan)) onListed();
  }

  const comments = (async () => {
    const queues = [...plans].map(([sub, plan]) => ({ sub, plan, queue: commentQueue(store, plan, full), touched: false }));
    const total = queues.reduce((n, q) => n + q.queue.length, 0);
    let done = 0;
    let rateLimited = false;
    onComments(done, total);
    // One thread from each subreddit in turn, so no subreddit waits for another's thirty.
    for (let i = 0; !rateLimited && queues.some((q) => i < q.queue.length); i++) {
      for (const q of queues) {
        if (i >= q.queue.length) continue;
        if (!alive()) return;
        try {
          if (await syncThreadComments(store, q.sub, q.queue[i], q.plan)) q.touched = true;
        } catch { rateLimited = true; break; }
        onComments(++done, total);
        // Feeds bring a thread a minute, so each one shows up as it lands; the API's come in batches.
        if (q.touched && (Reddit.feeds || done % 5 === 0)) { await rescoreSubreddit(store, q.sub); onListed(); }
      }
    }
    for (const q of queues) {
      await rescoreSubreddit(store, q.sub);
      await prune(store, q.sub, store.settings.threadsPerSubreddit);
      if (rateLimited && q.queue.some((p) => !store.threads.get(p.id)?.commentsFetchedAt)) q.sub.lastError = RATE_LIMITED;
      await DB.put('subs', q.sub);
    }
    onComments(total, total);
    onListed();
  })();
  return { synced: plans.size, comments };
}

async function rescoreSubreddit(store, sub) {
  const threads = [...store.threads.values()].filter((t) => t.sub === sub.id);
  const stats = {
    maxScore: threads.reduce((m, t) => Math.max(m, t.score), 0),
    maxComments: threads.reduce((m, t) => Math.max(m, t.numComments), 0),
    maxRank: threads.reduce((m, t) => Math.max(m, t.topRank || 0), 0),
  };
  const keywords = [...store.settings.boostKeywords, ...sub.keywords];
  for (const t of threads) {
    const detail = await DB.get('details', t.id);
    const r = scoreThread(t, (detail?.comments || []).map((c) => c.body), sub, stats, store.settings.weights, keywords);
    Object.assign(t, r);
  }
  await DB.put('threads', threads);
}

async function prune(store, sub, keep) {
  const threads = [...store.threads.values()].filter((t) => t.sub === sub.id && !t.isSaved && !t.savedOnReddit);
  if (threads.length <= keep) return;
  threads.sort((a, b) => b.relevance - a.relevance || b.score - a.score || (a.topRank || 1e9) - (b.topRank || 1e9));
  const drop = threads.slice(keep).map((t) => t.id);
  for (const id of drop) store.threads.delete(id);
  await DB.delete('threads', drop);
  await DB.delete('details', drop);
}

async function rescoreAll(store) {
  for (const sub of store.subs) await rescoreSubreddit(store, sub);
}
