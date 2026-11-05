// pocketpi service worker: shows web push notifications and opens the
// matching chat or run when one is tapped. No offline caching.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { title: "pocketpi", body: event.data && event.data.text() }; }
  event.waitUntil(self.registration.showNotification(data.title || "pocketpi", {
    body: data.body || "",
    tag: data.tag || undefined,
    data: { url: data.url || "/" },
    icon: "/icon-180.png",
    badge: "/icon-180.png",
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/", self.location.origin).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.location.origin)) { await w.focus(); return w.navigate(url); }
    }
    return self.clients.openWindow(url);
  })());
});
