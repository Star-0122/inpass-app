/* インパス（InPass）Service Worker
 * ------------------------------------------------------------
 * キャッシュのバージョン管理:
 * 新しいバージョンを公開するたびに、下の CACHE_NAME の数字を
 * 1つ増やしてください（例: inpass-v3 → inpass-v4）。
 * これにより、GitHub Pagesなどで古いHTML/JSがキャッシュされたまま
 * 表示され続ける問題を防ぎます（activate時に旧キャッシュを自動削除）。
 * ------------------------------------------------------------
 */
const CACHE_NAME = "inpass-v4";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./vendor/jsQR.js",
  "./vendor/qrcode.js",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
      caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).catch(() => {
        /* オフライン環境や、開発中のプレビューでは失敗しても致命的ではない */
      }),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
      caches.keys().then((keys) =>
        Promise.all(
            keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)),
        ),
      ),
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // 同一オリジンの静的アセットのみキャッシュ対象にする。
  // Googleフォントなど他オリジンへの通信はそのままネットワークへ通す。
  if (url.origin !== self.location.origin) {
    return;
  }
  if (req.method !== "GET") {
    return;
  }

  // ネットワーク優先：常に最新のファイルを取りに行き、
  // オフライン等で取得できない場合のみキャッシュにフォールバックする。
  // （以前は「キャッシュがあれば無条件にキャッシュを優先」という
  //   逆の実装になっており、更新が反映されない原因になっていた）
  event.respondWith(
      fetch(req, {cache: "no-store"})
          .then((res) => {
            if (res && res.status === 200) {
              const clone = res.clone();
              caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
            }
            return res;
          })
          .catch(() => caches.match(req)),
  );
});
