# iOS HLS Downloader

A native iPhone app with an embedded WKWebView browser for finding and downloading permitted HLS VOD streams.

## Implemented in the current prototype

- Detects M3U8 URLs observed through Fetch, XHR, and WebKit resource timing.
- Parses master and media playlists and displays available master-playlist variants for quality selection.
- Handles explicit and implicit BYTERANGE offsets for media segments and initialization maps.
- Downloads each media segment to a temporary file and appends it to the output incrementally.
- Supports identity AES-128-CBC encrypted media segments and playlist-derived IVs.
- Copies matching WKWebView cookies into URLSession requests for playlist, key, map, and segment URLs.
- Writes fMP4 playlists with EXT-X-MAP as .mp4.
- Attempts a real AVFoundation passthrough remux from MPEG-TS to MP4. If the system exporter cannot handle the stream, the original output remains a .ts file.
- Exposes completed files through the iOS share sheet and Files document sharing.

## Current limitations

This is an early prototype, not a finished downloader:

- Only finite VOD playlists with EXT-X-ENDLIST are accepted; live playlists are rejected.
- TS-to-MP4 conversion depends on AVFoundation supporting the source stream; there is no bundled FFmpeg remuxer.
- Encrypted fMP4 initialization maps, SAMPLE-AES, DRM, low-latency HLS, discontinuity handling, pause/resume, automatic retries, and background continuation are not implemented.
- Cookie forwarding is supported, but arbitrary site-specific request headers and JavaScript-generated authorization headers are not captured.
- WebView sniffing is best-effort and cannot observe every protected or non-WebKit media pipeline.

DRM circumvention and bypassing access controls are out of scope.

## Build and installation

GitHub Actions builds for a generic iOS device and packages an **unsigned** IPA artifact. The artifact must be signed with a certificate/profile or by a trusted sideloading tool before it can be installed on an iPhone. The workflow artifact is retained for seven days.
