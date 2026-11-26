# iOS HLS Downloader

A native iPhone app with an embedded browser for detecting and downloading permitted HLS media.

## Current implementation status

The initial project scaffold is being established. The intended feature set is:

- WKWebView browser with M3U8 request discovery
- HLS master/media playlist parsing
- BYTERANGE support, including implicit offsets
- AES-128 encrypted segments
- Streaming-to-disk downloads (no whole-video in-memory assembly)
- fMP4 output when the playlist provides an initialization segment
- MPEG-TS output with a truthful .ts extension until a real remuxer is integrated
- Files app export

DRM-protected streams and bypassing access controls are out of scope.

## Build

The project uses XcodeGen and GitHub Actions. The workflow will build for a generic iOS device without signing. An unsigned build is not directly installable; signing with a user's own certificate is required for installation on an iPhone.

## Requirements

- Xcode
- XcodeGen
