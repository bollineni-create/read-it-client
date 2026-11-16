// With feeds, Reddit allows an address about one request a minute. reddit.js keeps to the budget
// the server route passes on, and takes an answer the site's edge already has instead of waiting.
// Run: node --test web/test/*.test.js
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { parseListing, parseComments } = require('../js/core.js');

const SOURCE = fs.readFileSync(path.join(__dirname, '../js/reddit.js'), 'utf8');
const LISTING = { data: { children: [], after: null } };

/**
 * Loads reddit.js against a clock the test moves by hand and a `fetch` it answers.
 * `answer(call)` gets `{ url, cachedOnly, at }` and returns `{ status, headers, body }`.
 */
function load(answer) {
  let now = 1_000_000;
  const timers = [];
  const calls = [];
  const reply = ({ status = 200, headers = {}, body = LISTING }) => ({
    status, ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null },
    json: async () => body,
  });
  const context = vm.createContext({
    console, URLSearchParams, parseListing, parseComments,
    Date: { now: () => now },
    setTimeout: (fn, ms) => { timers.push({ at: now + Math.max(0, ms), fn }); },
    fetch: async (url, init = {}) => {
      if (url === 'api/status') return reply({ headers: { 'content-type': 'application/json' }, body: { rounds: true, feeds: true } });
      const call = { url, cachedOnly: !!(init.headers && init.headers['x-rounds-cached-only']), at: now - 1_000_000 };
      calls.push(call);
      return reply(answer(call));
    },
  });
  vm.runInContext(`${SOURCE}\nthis.Reddit = Reddit;`, context);
  /** Runs timers in order, moving the clock, until `promise` settles. */
  async function settle(promise) {
    let done = false;
    let outcome;
    promise.then((value) => { done = true; outcome = { value }; }, (error) => { done = true; outcome = { error }; });
    for (let i = 0; i < 10_000 && !done; i++) {
      await new Promise((r) => setImmediate(r));
      if (done) break;
      timers.sort((a, b) => a.at - b.at);
      const next = timers.shift();
      if (!next) continue;
      now = Math.max(now, next.at);
      next.fn();
    }
    assert.ok(done, 'the request never finished');
    return outcome;
  }
  const real = () => calls.filter((c) => !c.cachedOnly);
  return { Reddit: context.Reddit, calls, real, settle, elapsed: () => now - 1_000_000 };
}

const spent = (reset) => ({ 'x-reddit-remaining': '0', 'x-reddit-reset': String(reset) });

test('requests fired together reach Reddit one at a time, each after the budget refills', async () => {
  const h = load((call) => (call.cachedOnly ? { status: 204 } : { headers: spent(30) }));
  await h.Reddit.detect();
  const all = Promise.all([h.Reddit.top('mdphd', 'month', 100), h.Reddit.hot('mdphd', 50), h.Reddit.top('mcat', 'month', 100)]);
  const { error } = await h.settle(all);
  assert.equal(error, undefined);
  const at = h.real().map((c) => c.at);
  assert.equal(at.length, 3);
  assert.equal(at[0], 0);
  assert.ok(at[1] >= 30_000, `second request went after ${at[1]} ms`);
  assert.ok(at[2] - at[1] >= 30_000, `third request went ${at[2] - at[1]} ms after the second`);
});

test('while it would wait, the page takes an answer the edge already has', async () => {
  const h = load((call) => {
    if (call.url.includes('sub=mcat')) return call.cachedOnly
      // An edge copy still carries the budget Reddit reported when the copy was made.
      ? { headers: { 'x-vercel-cache': 'HIT', 'x-reddit-remaining': '0', 'x-reddit-reset': '55' } }
      : { headers: spent(60) };
    return call.cachedOnly ? { status: 204 } : { headers: spent(60) };
  });
  await h.Reddit.detect();
  await h.settle(h.Reddit.top('mdphd', 'month', 100));
  const { error } = await h.settle(h.Reddit.top('mcat', 'month', 100));
  assert.equal(error, undefined);
  assert.equal(h.elapsed(), 0, 'the cached answer did not wait');
  assert.equal(h.real().length, 1, 'Reddit was asked once');
  // The copy's old budget headers don't move the clock: the next uncached request waits for the first one's minute.
  await h.settle(h.Reddit.hot('mdphd', 50));
  assert.ok(h.real()[1].at >= 60_000 && h.real()[1].at < 62_000, `next request went after ${h.real()[1].at} ms`);
});

test('a refusal waits as long as Reddit says, then the request goes through', async () => {
  let refusals = 1;
  const h = load((call) => {
    if (call.cachedOnly) return { status: 204 };
    return refusals-- > 0 ? { status: 429, headers: { 'retry-after': '20', ...spent(20) }, body: { error: 'x', reason: 'rate_limited' } } : { headers: spent(60) };
  });
  await h.Reddit.detect();
  const { value, error } = await h.settle(h.Reddit.top('mdphd', 'month', 100));
  assert.equal(error, undefined);
  assert.deepEqual(Array.from(value.posts), []);
  const at = h.real().map((c) => c.at);
  assert.equal(at.length, 2);
  assert.ok(at[1] >= 20_000 && at[1] < 22_000, `retried after ${at[1]} ms`);
});

test('a request Reddit keeps refusing gives up and says why', async () => {
  const h = load((call) => (call.cachedOnly ? { status: 204 } : { status: 429, headers: { 'retry-after': '60' }, body: { reason: 'rate_limited' } }));
  await h.Reddit.detect();
  const { error } = await h.settle(h.Reddit.top('mdphd', 'month', 100));
  assert.equal(error?.status, 429);
  assert.equal(h.real().length, 5, 'one try and four retries');
});
