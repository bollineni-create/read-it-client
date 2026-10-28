// Local storage in IndexedDB: subreddits, threads, thread details (comments and resources)
// and settings. Everything but details is kept in memory too; the data set is small.
'use strict';

const DB = (() => {
  let db = null;
  const open = () => new Promise((resolve, reject) => {
    const req = indexedDB.open('rounds', 1);
    req.onupgradeneeded = () => {
      const d = req.result;
      d.createObjectStore('subs', { keyPath: 'id' });
      d.createObjectStore('threads', { keyPath: 'id' });
      d.createObjectStore('details', { keyPath: 'id' });
      d.createObjectStore('kv');
    };
    req.onsuccess = () => resolve(db = req.result);
    req.onerror = () => reject(req.error);
  });
  const done = (tx) => new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onerror = tx.onabort = () => reject(tx.error); });
  const result = (req) => new Promise((resolve, reject) => { req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); });

  return {
    async init() { if (!db) await open(); },
    all: (store) => result(db.transaction(store).objectStore(store).getAll()),
    get: (store, key) => result(db.transaction(store).objectStore(store).get(key)),
    async put(store, values) {
      const tx = db.transaction(store, 'readwrite');
      const os = tx.objectStore(store);
      for (const v of [].concat(values)) os.put(v);
      return done(tx);
    },
    async delete(store, keys) {
      const tx = db.transaction(store, 'readwrite');
      const os = tx.objectStore(store);
      for (const k of [].concat(keys)) os.delete(k);
      return done(tx);
    },
    getKV: (key) => result(db.transaction('kv').objectStore('kv').get(key)),
    async setKV(key, value) {
      const tx = db.transaction('kv', 'readwrite');
      tx.objectStore('kv').put(value, key);
      return done(tx);
    },
    async clear() {
      const tx = db.transaction(['subs', 'threads', 'details', 'kv'], 'readwrite');
      for (const s of ['subs', 'threads', 'details', 'kv']) tx.objectStore(s).clear();
      return done(tx);
    },
  };
})();
