# iOS HLS Downloader

A native iPhone app with an embedded WKWebView browser for finding and downloading permitted HLS VOD streams.

## Implemented in the current prototype

- Detects M3U8 URLs observed through Fetch, XHR, and WebKit resource timing.
- Parses master and media playlists and currently selects the highest-bandwidth variant automatically.
- Handles explicit and implicit BYTERANGE offsets for media segments and initialization maps.
- Downloads each media segment to a temporary file and appends it to the output incrementally.
- Supports identity AES-128-CBC encrypted segments and playlist-derived IVs.
- Copies matching WKWebView cookies into URLSession requests for playlist, key, map, and segment URLs.
- Writes fMP4 playlists with EXT-X-MAP as .mp4 and MPEG-TS playlists as .ts.
- Exposes completed files through the iOS share sheet and Files document sharing.

## Current limitations

This is an early prototype, not a finished downloader:

- Only finite VOD playlists with EXT-X-ENDLIST are accepted; live playlists are rejected.
- Master playlists currently choose the highest-bandwidth variant automatically; there is not yet a manual quality selector.
- MPEG-TS output remains a genuine .ts file. It is not renamed to .mp4; TS-to-MP4 remuxing is not implemented yet.
- Encrypted fMP4 initialization maps, SAMPLE-AES, DRM, low-latency HLS, discontinuity handling, pause/resume, automatic retries, and background continuation are not implemented.
- Cookie forwarding is supported, but arbitrary site-specific request headers and JavaScript-generated authorization headers are not captured.
- WebView sniffing is best-effort and cannot observe every protected or non-WebKit media pipeline.

DRM circumvention and bypassing access controls are out of scope.

## Build and installation

GitHub Actions builds for a generic iOS device and packages an **unsigned** IPA artifact. The artifact must be signed with a certificate/profile or by a trusted sideloading tool before it can be installed on an iPhone. The workflow artifact is retained for seven days.
