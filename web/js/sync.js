// Sync, ported from the Mac app's SyncEngine: fetch top (and hot) posts per subreddit,
// fetch comments where they changed, rebuild resources, rescore and prune.
'use strict';

// The browser shares Reddit's per-IP limits, so a sync fetches at most this many comment
// threads per subreddit; the rest are picked up by later syncs.
const COMMENT_FETCHES_PER_SUB = 30;
const DAY = 86400e3;

async function syncSubreddit(store, sub, { full = false, onProgress = () => {} } = {}) {
  const settings = store.settings;
  const keep = settings.threadsPerSubreddit;
  const minUp = settings.minimumUpvotes;
  const hide = settings.hideImageAndMemePosts;
  const storedLimit = settings.commentsPerThread || null; // 0 = all
  const requestLimit = settings.commentsPerThread || 500;

  try {
    onProgress(`Fetching r/${sub.name}…`);
    const posts = [];
    const seen = new Set();
    let after = null;
    do {
      const page = await Reddit.top(sub.name, sub.window, Math.min(100, keep - posts.length), after);
      for (const p of page.posts) if (!seen.has(p.id)) { seen.add(p.id); posts.push(p); }
      after = page.after;
      if (!page.posts.length) break;
    } while (after && posts.length < keep);
    const hot = await Reddit.hot(sub.name, 50);
    for (const p of hot.posts) if (!p.stickied && !seen.has(p.id)) { seen.add(p.id); posts.push(p); }

    const canonical = posts[0]?.subreddit;
    if (canonical && canonical !== sub.name && canonical.toLowerCase() === sub.id) sub.name = canonical;

    posts.sort((a, b) => b.score - a.score);
    let fetches = 0;
    const now = Date.now();
    for (const [i, post] of posts.entries()) {
      const old = store.threads.get(post.id);
      const saved = !!(old?.isSaved || old?.savedOnReddit);
      const skipped = post.score < minUp || (hide && isImageOrMeme(post));
      let needs;
      if (skipped && !saved) needs = false;
      else if (!old || !old.commentsFetchedAt) needs = true;
      else if (full && now - old.commentsFetchedAt > DAY) needs = true;
      else needs = old.numComments !== post.numComments;
      if (needs && fetches >= COMMENT_FETCHES_PER_SUB) needs = false;

      let built;
      if (needs) {
        fetches++;
        onProgress(`r/${sub.name}: comments ${fetches} (${i + 1}/${posts.length})`);
        try {
          const res = await Reddit.comments(post.id, requestLimit);
          built = buildThread(res.post || post, sub.id, res.tree, storedLimit, old);
          await DB.put('details', { id: post.id, comments: built.comments, resources: built.resources });
        } catch (e) {
          if (e.status === 429) throw e;
          needs = false;
        }
      }
      if (!built) {
        built = buildThread(post, sub.id, [], 0, old);
        if (old) {
          built.thread.linkCount = Math.max(built.thread.linkCount, old.linkCount);
          built.thread.maxDepth = old.maxDepth;
          built.thread.commentsFetchedAt = old.commentsFetchedAt;
          if (old.kind === 'resource') built.thread.kind = 'resource';
        } else {
          built.thread.commentsFetchedAt = null;
          await DB.put('details', { id: post.id, comments: [], resources: built.resources });
        }
      }
      store.threads.set(post.id, built.thread);
    }

    await rescoreSubreddit(store, sub);
    await prune(store, sub, keep);
    sub.lastSynced = Date.now();
    sub.lastError = null;
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
  threads.sort((a, b) => b.relevance - a.relevance || b.score - a.score);
  const drop = threads.slice(keep).map((t) => t.id);
  for (const id of drop) store.threads.delete(id);
  await DB.delete('threads', drop);
  await DB.delete('details', drop);
}

async function rescoreAll(store) {
  for (const sub of store.subs) await rescoreSubreddit(store, sub);
}
