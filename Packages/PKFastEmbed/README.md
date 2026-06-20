# PKFastEmbed

PKFastEmbed is the owned native companion for PositronicKit's in-process
`all-MiniLM-L6-v2` backend. It wraps FastEmbed behind a versioned C ABI and a
serialized Swift API. The runtime never downloads models; callers supply a
directory containing the pinned, checksummed assets.

## Bootstrap

```bash
./bootstrap.sh --prefix /path/to/prefix
export PKG_CONFIG_PATH=/path/to/prefix/lib/pkgconfig
swift test
```

Model asset checksums are recorded in `model-assets.sha256`. The pinned model
revision is `5f1b8cd78bc4fb444dd171e59b18f3a3af89a079`.

## Design Choices

- SwiftPM binary targets are not used because they are supported only on Apple
  platforms and cannot provide the required Linux distribution path.
- `swift-embeddings` and `swift-transformers` do not provide the required pinned
  MiniLM ONNX inference contract across all target platforms.
- llama.cpp targets a different model/runtime format and would add a larger,
  unrelated inference surface.
- Cargo builds a locked native static library; SwiftPM consumes only the stable
  C ABI through pkg-config.

## Licensing

Downstream distributions must preserve the licenses and notices for FastEmbed,
ONNX Runtime, Hugging Face tokenizers, and the Apache-2.0 licensed
`sentence-transformers/all-MiniLM-L6-v2` model. See `THIRD_PARTY_NOTICES.md`.
