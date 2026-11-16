// Sync, ported from the Mac app's SyncEngine: fetch top (and hot) posts per subreddit,
// fetch comments where they changed, rebuild resources, rescore and prune.
'use strict';

// Reddit allows only so many requests a minute, so a sync fetches at most this many comment
// threads per subreddit; the rest are picked up by later syncs.
const COMMENT_FETCHES_PER_SUB = 30;
const DAY = 86400e3;
const RATE_LIMITED = 'Reddit is rate-limiting requests. The remaining comments will load on the next sync.';

async function syncSubreddit(store, sub, { full = false, onProgress = () => {}, onListed = () => {} } = {}) {
  const settings = store.settings;
  const keep = settings.threadsPerSubreddit;
  const minUp = settings.minimumUpvotes;
  const hide = settings.hideImageAndMemePosts;
  const storedLimit = settings.commentsPerThread || null; // 0 = all
  const requestLimit = settings.commentsPerThread || 500;

  try {
    onProgress(`Fetching r/${sub.name}…`);
    // 1. Listings. A post's place in the top listing becomes its rank, which stands in for the score feeds don't carry.
    const posts = [];
    const seen = new Set();
    const ranks = new Map();
    let after = null;
    do {
      const page = await Reddit.top(sub.name, sub.window, Math.min(100, keep - posts.length), after);
      for (const p of page.posts) if (!seen.has(p.id)) { seen.add(p.id); posts.push(p); ranks.set(p.id, posts.length); }
      after = page.after;
      if (!page.posts.length) break;
    } while (after && posts.length < keep);
    const hot = await Reddit.hot(sub.name, 50);
    for (const p of hot.posts) if (!p.stickied && !seen.has(p.id)) { seen.add(p.id); posts.push(p); }

    const canonical = posts[0]?.subreddit;
    if (canonical && canonical !== sub.name && canonical.toLowerCase() === sub.id) sub.name = canonical;

    const rankOf = (p) => ranks.get(p.id) ?? Infinity;
    posts.sort((a, b) => b.score - a.score || (rankOf(a) === rankOf(b) ? 0 : rankOf(a) - rankOf(b)));

    // 2. Which threads need their comments (best first).
    const now = Date.now();
    const fetched = (p) => !!store.threads.get(p.id)?.commentsFetchedAt;
    let queue = posts.filter((post) => {
      const old = store.threads.get(post.id);
      const lowScore = post.score >= 0 && post.score < minUp;
      if ((lowScore || (hide && isImageOrMeme(post))) && !(old?.isSaved || old?.savedOnReddit)) return false;
      if (!old || !old.commentsFetchedAt) return true;
      if (full && now - old.commentsFetchedAt > DAY) return true; // a full pass also refreshes day-old comments
      // Feeds don't say how many comments a thread has, so only age triggers a refresh there.
      return post.numComments >= 0 && old.numComments !== post.numComments;
    });
    // Threads never fetched go first, so a capped pass fills gaps before it refreshes.
    queue = [...queue.filter((p) => !fetched(p)), ...queue.filter(fetched)].slice(0, COMMENT_FETCHES_PER_SUB);

    // 3. Store every post first, so the list fills in before the slower comment requests.
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
    // A thread that has dropped out of the top listing no longer has a place in it.
    for (const t of store.threads.values()) if (t.sub === sub.id && !ranks.has(t.id)) t.topRank = null;
    await rescoreSubreddit(store, sub);
    onListed();

    // 4. Comments.
    let rateLimited = false;
    for (const [i, post] of queue.entries()) {
      onProgress(`r/${sub.name}: comments ${i + 1} of ${queue.length}`);
      try {
        const res = await Reddit.comments(post.id, requestLimit);
        const built = buildThread(res.post || post, sub.id, res.tree, storedLimit, store.threads.get(post.id), ranks.get(post.id) ?? null);
        await DB.put('details', { id: post.id, comments: built.comments, resources: built.resources });
        store.threads.set(post.id, built.thread);
      } catch (e) {
        // Rate-limited: stop asking and keep what's here. One thread failing any other way doesn't stop the rest.
        if (e.status === 429) { rateLimited = true; break; }
      }
    }

    // 5. Score and prune.
    await rescoreSubreddit(store, sub);
    await prune(store, sub, keep);
    sub.lastSynced = Date.now();
    sub.lastError = rateLimited ? RATE_LIMITED : null;
  } catch (e) {
    sub.lastError = e.message || String(e);
    throw e;
  } finally {
    await DB.put('subs', sub);
  }
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
