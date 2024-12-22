const filesToCache = [
	"index.html",
	"disc.iso",
	"halfix.js",
	"halfix.json",
	"halfix.wasm",
	"bios.bin",
	"FavIcon_16x16.png",
	"FavIcon_192x192.png",
	"FavIcon_512x512.png",
	"libhalfix.js",
	"vgabios.bin"
];

const staticCacheName = "halfix-x";

self.addEventListener("install", event => {
	event.waitUntil(
		caches.open(staticCacheName)
		.then(cache => {
			return cache.addAll(filesToCache);
		})
	);
});

self.addEventListener("fetch", event => {
	event.respondWith(
		caches.match(event.request)
		.then(response => {
			if (response) {
				return response;
			}
			return fetch(event.request)
		}).catch(error => {
		})
	);
});