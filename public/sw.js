const cache='relay-offline-v1';
self.addEventListener('install',e=>e.waitUntil(caches.open(cache).then(c=>c.add('/offline.html')).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('relay-offline-')&&k!==cache).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
  // Only a generic offline document is cached. No private, API, or media responses.
  if(e.request.mode==='navigate' && new URL(e.request.url).origin===self.location.origin) e.respondWith(fetch(e.request).catch(()=>caches.match('/offline.html')));
});
