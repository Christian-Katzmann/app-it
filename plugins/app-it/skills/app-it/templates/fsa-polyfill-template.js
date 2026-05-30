// File System Access polyfill for the app-it Swift WebKit shell.
//
// WHY THIS EXISTS
// WebKit does not implement window.showDirectoryPicker, FileSystemDirectoryHandle,
// FileSystemFileHandle, or anything else under the File System Access API.
// Apps that gate behavior on `'showDirectoryPicker' in window` will show a
// "Browser not supported" message inside our wrapper window. This file
// polyfills the API surface enough to let those apps boot.
//
// WHEN THIS WORKS WELL
// Apps that use FSA only as a "remember a folder" seam — the user picks a
// folder once, the app stores the handle in IndexedDB to remember it across
// sessions, and all REAL file I/O goes through a server-side API (e.g. Vite
// middleware, Express routes, etc.) rather than through the JS handle.
//
// WHEN THIS DOES NOT WORK
// Apps that actually read or write file contents through the FSA handle from
// JS (handle.getFile() → blob, handle.createWritable() → WritableStream) need
// real bridges to native filesystem code. Synthetic handles can't satisfy
// that contract. If grep finds .createWritable() or .getFile() being awaited
// for actual data, this polyfill is the wrong tool — consider Strategy D
// (Tauri) or rework the app to route I/O through the dev server.
//
// CUSTOMIZE THESE PER PROJECT
// The agent fills these in based on grep results from the project. The
// IndexedDB names below are stand-ins; the actual values come from the app's
// FSA reconnect logic (search for `indexedDB.open(`, store names, key names).
const WORKSPACE_PATH = '__WORKSPACE_PATH__';            // absolute path to the folder users would have picked
const WORKSPACE_NAME = '__WORKSPACE_NAME__';            // display name of that folder (often the basename)
const APP_DB_NAME    = '__APP_DB_NAME__';               // e.g. 'foo_studio_workspace'
const APP_STORE_NAME = '__APP_STORE_NAME__';            // e.g. 'handles'
const APP_KEY_NAME   = '__APP_KEY_NAME__';              // e.g. 'workspaceRoot'

// ----------------------------------------------------------------------
(function () {
  // If WebKit ever grows native FSA support, defer to it.
  if ('showDirectoryPicker' in window) return;

  const MARKER = '__app-itSyntheticHandle';

  function reconstituteDir(rec) {
    return makeDirHandle(rec.__path, rec.name);
  }

  function makeDirHandle(path, name) {
    return {
      kind: 'directory',
      name: name,
      [MARKER]: 'directory',
      __path: path,
      queryPermission: function () { return Promise.resolve('granted'); },
      requestPermission: function () { return Promise.resolve('granted'); },
      getDirectoryHandle: function (childName) {
        return Promise.resolve(makeDirHandle(path + '/' + childName, childName));
      },
      getFileHandle: function (childName) {
        return Promise.resolve(makeFileHandle(path + '/' + childName, childName));
      },
      removeEntry: function () { return Promise.resolve(); },
      isSameEntry: function (other) {
        return Promise.resolve(!!other && other.__path === path);
      },
      keys:    async function* () {},
      values:  async function* () {},
      entries: async function* () {},
    };
  }

  function makeFileHandle(path, name) {
    return {
      kind: 'file',
      name: name,
      [MARKER]: 'file',
      __path: path,
      queryPermission: function () { return Promise.resolve('granted'); },
      requestPermission: function () { return Promise.resolve('granted'); },
      getFile: function () {
        return Promise.reject(
          new Error('FSA file read is unsupported in the app-it shell — route through a server API')
        );
      },
      createWritable: function () {
        return Promise.reject(
          new Error('FSA file write is unsupported in the app-it shell — route through a server API')
        );
      },
    };
  }

  // Pretend a directory was picked.
  window.showDirectoryPicker = function () {
    return Promise.resolve(makeDirHandle(WORKSPACE_PATH, WORKSPACE_NAME));
  };

  // Wrap indexedDB.open for the app's workspace DB so reads of the synthetic
  // record reconstitute methods on the way out (structured clone strips
  // function properties between put and get — we have to put them back).
  const originalOpen = indexedDB.open.bind(indexedDB);
  indexedDB.open = function (name, version) {
    const req = originalOpen(name, version);
    if (name !== APP_DB_NAME) return req;

    req.addEventListener('success', function () {
      const db = req.result;
      const origTransaction = db.transaction.bind(db);
      db.transaction = function (storeNames, mode) {
        const tx = origTransaction(storeNames, mode);
        const origObjectStore = tx.objectStore.bind(tx);
        tx.objectStore = function (storeName) {
          const store = origObjectStore(storeName);
          if (storeName !== APP_STORE_NAME) return store;
          const origGet = store.get.bind(store);
          store.get = function (key) {
            const r = origGet(key);
            r.addEventListener('success', function () {
              const rec = r.result;
              if (rec && rec[MARKER] === 'directory') {
                Object.defineProperty(r, 'result', {
                  configurable: true,
                  value: reconstituteDir(rec),
                });
              }
            });
            return r;
          };
          return store;
        };
        return tx;
      };
    });
    return req;
  };

  // Pre-seed the workspace handle so the app's reconnect-on-load path finds
  // something and skips the picker entirely. Idempotent — overwriting the
  // same record on every launch is fine.
  const seed = originalOpen(APP_DB_NAME, 1);
  seed.onupgradeneeded = function (e) {
    const db = e.target.result;
    if (!db.objectStoreNames.contains(APP_STORE_NAME)) {
      db.createObjectStore(APP_STORE_NAME);
    }
  };
  seed.onsuccess = function (e) {
    try {
      const db = e.target.result;
      const tx = db.transaction(APP_STORE_NAME, 'readwrite');
      tx.objectStore(APP_STORE_NAME).put(
        {
          kind: 'directory',
          name: WORKSPACE_NAME,
          __path: WORKSPACE_PATH,
          [MARKER]: 'directory',
        },
        APP_KEY_NAME
      );
    } catch (_) {}
  };
})();
