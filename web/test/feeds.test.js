// Threads that come from Reddit's feeds have no upvote or comment counts (-1).
// Run: node --test web/test/
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseListing, parseComments, buildThread, postFromThread, scoreThread, rankSignal } = require('../js/core.js');

const feedPost = (id, extra = {}) => ({ kind: 't3', data: {
  id, subreddit: 'mdphd', title: 'MSTP interviews: what I wish I knew', selftext: 'My tracker: [sheet](https://docs.google.com/spreadsheets/d/abc/edit)',
  author: 'someone', score: -1, num_comments: -1, created_utc: 1792708411, permalink: `/r/mdphd/comments/${id}/slug/`,
  url: `https://www.reddit.com/r/mdphd/comments/${id}/slug/`, post_hint: null, is_self: true, is_gallery: false, is_video: false, ...extra } });
const feedComments = (n) => [{ kind: 'Listing', data: { children: [] } }, { kind: 'Listing', data: { children:
  Array.from({ length: n }, (_, i) => ({ kind: 't1', data: { id: `c${i}`, author: 'alpha', body: `Comment ${i}`, score: -1, depth: 0, replies: '' } })) } }];
const weights = { upvotes: 0.35, discussion: 0.25, resources: 0.2, keywords: 0.2 };
const sub = { name: 'mdphd', window: 'month' };

test('a feed post keeps "unknown" counts instead of zero', () => {
  const [post] = parseListing({ data: { children: [feedPost('f1')] } }).posts;
  assert.equal(post.score, -1);
  assert.equal(post.numComments, -1);
  const { thread } = buildThread(post, 'mdphd', [], 0, null, 3);
  assert.equal(thread.score, -1);
  assert.equal(thread.numComments, 0);
  assert.equal(thread.topRank, 3);
  assert.equal(thread.commentsFetchedAt, null);
});

test('a feed thread counts the comments it was given', () => {
  const [post] = parseListing({ data: { children: [feedPost('f1')] } }).posts;
  const res = parseComments(feedComments(6));
  assert.equal(res.post, null);
  const { thread, comments } = buildThread(post, 'mdphd', res.tree, 20, null, 1);
  assert.equal(comments.length, 6);
  assert.equal(thread.numComments, 6);
  assert.ok(thread.commentsFetchedAt > 0);
  assert.deepEqual(comments.map((c) => c.score), [-1, -1, -1, -1, -1, -1]);
});

test('counts already known survive a feed refresh', () => {
  const [post] = parseListing({ data: { children: [feedPost('f1')] } }).posts;
  const existing = { score: 412, numComments: 57, commentsFetchedAt: 123, relevance: 50, why: '', matchedKeywords: [] };
  const { thread } = buildThread(post, 'mdphd', [], 0, existing, 2);
  assert.equal(thread.score, 412);
  assert.equal(thread.numComments, 57);
  assert.equal(thread.commentsFetchedAt, 123);
});

test('a stored thread rebuilds from comments alone, keeping its link and rank', () => {
  const [post] = parseListing({ data: { children: [feedPost('f4', { selftext: '', is_self: false, url: 'https://www.nature.com/articles/abc' })] } }).posts;
  const first = buildThread(post, 'mdphd', [], 0, null, 4).thread;
  assert.equal(first.postURL, 'https://www.nature.com/articles/abc');
  const again = buildThread(postFromThread(first, true), 'mdphd', parseComments(feedComments(3)).tree, 20, first, first.topRank).thread;
  assert.equal(again.postURL, 'https://www.nature.com/articles/abc');
  assert.equal(again.topRank, 4);
  assert.equal(again.score, -1);
  assert.equal(again.numComments, 3);
  assert.equal(again.linkCount, 1);
});

test('rank stands in for upvotes when scoring', () => {
  assert.equal(rankSignal(1, 100), 1);
  assert.ok(Math.abs(rankSignal(100, 100) - 0.01) < 1e-9);
  assert.equal(rankSignal(null, 100), 0);
  assert.ok(Math.abs(rankSignal(5, 0) - 0.2) < 1e-9);
  const base = { title: 'x', body: '', subName: 'mdphd', numComments: 0, maxDepth: 0, linkCount: 0 };
  const stats = { maxScore: 0, maxComments: 0, maxRank: 100 };
  const top = scoreThread({ ...base, score: -1, topRank: 1 }, [], sub, stats, weights, []);
  const low = scoreThread({ ...base, score: -1, topRank: 90 }, [], sub, stats, weights, []);
  const none = scoreThread({ ...base, score: -1, topRank: null }, [], sub, stats, weights, []);
  assert.ok(top.relevance > low.relevance && low.relevance > none.relevance);
  assert.equal(top.why, 'Top post in r/mdphd this month');
  assert.equal(none.why, 'New in r/mdphd');
  // With real scores the upvote signal is unchanged.
  const scored = scoreThread({ ...base, score: 500, topRank: 90 }, [], sub, { ...stats, maxScore: 500 }, weights, []);
  assert.equal(scored.relevance, top.relevance);
});

test('the reason names the rank, never "-1 upvotes"', () => {
  const t = { title: 'x', body: '', subName: 'mdphd', score: -1, topRank: 2, numComments: 40, maxDepth: 0, linkCount: 0 };
  const r = scoreThread(t, [], sub, { maxScore: 0, maxComments: 40, maxRank: 100 }, { ...weights, upvotes: 0.2, discussion: 0.4 }, []);
  assert.match(r.why, /#2 of the top posts/);
  assert.doesNotMatch(r.why, /-1/);
});
