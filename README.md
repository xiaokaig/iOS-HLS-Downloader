# iOS HLS Downloader

A native iPhone app with an embedded WKWebView browser for finding and downloading permitted HLS VOD streams.

## Implemented in the current prototype

- Detects M3U8 URLs observed through Fetch, XHR, and WebKit resource timing.
- Parses master and media playlists and displays available master-playlist variants for quality selection.
- Handles explicit and implicit BYTERANGE offsets for media segments and initialization maps.
- Downloads media segments with a six-worker concurrent scheduler, then assembles them in playlist order.
- Persists completed segment files under Application Support so a repeated download of the same playlist can reuse completed segments after an interruption; failed segments are retried up to three times.
- Supports identity AES-128-CBC encrypted media segments and playlist-derived IVs.
- Copies matching WKWebView cookies into URLSession requests for playlist, key, map, and segment URLs.
- Writes fMP4 playlists with EXT-X-MAP as .mp4.
- Attempts a real AVFoundation passthrough remux from MPEG-TS to MP4. If the system exporter cannot handle the stream, the original output remains a .ts file.
- Exposes completed files through the iOS share sheet and Files document sharing.

## Current limitations

This is an early prototype, not a finished downloader:

- Only finite VOD playlists with EXT-X-ENDLIST are accepted; live playlists are rejected.
- TS-to-MP4 conversion depends on AVFoundation supporting the source stream; there is no bundled FFmpeg remuxer.
- The current resume cache is keyed by the playlist URL and is reused when the same download is started again; there is not yet a persisted in-app task list or one-tap automatic recovery UI.
- Pause/resume controls and a dedicated background URLSession implementation are not yet implemented. iOS may suspend ordinary foreground URLSession work when the app enters the background; completed segment files remain cached, but uninterrupted background downloading is not guaranteed.
- Encrypted fMP4 initialization maps, SAMPLE-AES, DRM, low-latency HLS, and discontinuity handling are not implemented.
- Cookie forwarding is supported, but arbitrary site-specific request headers and JavaScript-generated authorization headers are not captured.
- WebView sniffing is best-effort and cannot observe every protected or non-WebKit media pipeline.

DRM circumvention and bypassing access controls are out of scope.

## Build and installation

GitHub Actions builds for a generic iOS device and packages an **unsigned** IPA artifact. The artifact must be signed with a certificate/profile or by a trusted sideloading tool before it can be installed on an iPhone. The workflow artifact is retained for seven days.

## Browser rewrite (branch: browser-rewrite)

The browser module is being separated from address-field presentation state:

- Only explicit user actions call the browser controller to load, reload, stop, go back, or go forward.
- SwiftUI view updates never issue a navigation request.
- WebKit owns ordinary links, redirects, forms, and history navigation; the navigation delegate only makes policy decisions and records lifecycle events.
- Popup links are routed into the current browser view through the WebKit UI delegate.
- HLS sniffing remains independently switchable and deduplicates repeated playlist notifications.
- Diagnostics are bounded to approximately 2 MB, coalesce repeated events, redact common credential query parameters, and copy only the latest 200 lines.

### Browser acceptance checklist

1. Launch with HLS sniffing enabled; open a normal HTTPS page.
2. Search for a term, open multiple result links, then use back and forward.
3. Open GitHub and follow an internal link; confirm the address bar follows the page without returning to the previous URL.
4. Open a link that requests a new window; confirm it opens in the current browser tab.
5. Refresh, stop a loading page, and rebuild the browser.
6. Repeat the same checks with HLS sniffing disabled, then enabled again.
7. Play a permitted HLS VOD page and confirm its playlist appears once in the candidate list.
8. Confirm repeated navigation cancellations do not produce a connection-failure flood and that copied logs contain no more than 200 lines.

The rewrite branch is not considered release-ready until the iOS build succeeds and these device checks pass.

