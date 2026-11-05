# Docling Serve OCI image

A Nix-built CPU image for Docling Serve 1.38.0. It builds from the pinned upstream source and Python lockfile with `pkgs.dockerTools`; it does not wrap an upstream container image.

## Build

```sh
nix flake check
nix build .#image
```

The flake pins Nixpkgs and the Docling Serve source revision; the upstream `uv.lock` is used for the Python dependency graph. The image output is a container archive. These commands do not import or deploy it.

## Runtime contract

- Supported platform: `x86_64-linux`.
- Runs as numeric non-root UID:GID `10001:10001`.
- Entrypoint: `docling-serve run --host 0.0.0.0 --port 5001`; TCP port metadata: `5001`.
- OCI healthcheck: `GET /ready` through the bundled Python interpreter. Start period is 30 minutes to allow cold model loading; `/health` is a basic process check, with `/readyz` and `/livez` also available.
- Authentication is disabled by default. Set `DOCLING_SERVE_API_KEY` through a secret manager. HTTP API requests use the `X-Api-Key` header; WebSocket conversion uses an `api_key` query parameter, which can leak into proxy logs. The container binds all interfaces, so restrict network exposure before allowing untrusted clients.
- Upstream request limits default to effectively unlimited. Set `DOCLING_SERVE_MAX_FILE_SIZE` and `DOCLING_SERVE_MAX_NUM_PAGES` or enforce equivalent limits at a proxy.
- The default upstream model-loading behavior is retained. A cold start may download models and needs outbound network access; set `DOCLING_SERVE_LOAD_MODELS_AT_BOOT=false` to defer boot loading, noting that the first conversion may still need model downloads.

## Writable paths and weights

- `/data` is the persistent volume and home directory.
- Hugging Face model/cache data uses `/data/huggingface`.
- RapidOCR model downloads use `/data/rapidocr-models`. The image removes the small ONNX model files bundled in the RapidOCR wheel and directs runtime downloads to this writable path.
- `/tmp` is created mode 1777 for scratch files. For a read-only root filesystem, mount `/data` as writable storage and `/tmp` as tmpfs. Ensure mounted storage is writable as UID/GID 10001 in the chosen user namespace.
- No Docling or RapidOCR model weights are baked into the image. Keep `/data` persistent if you want to reuse downloads; offline use requires pre-populating the appropriate model caches.

The image includes CA certificates for runtime HTTPS downloads, but provides no conventional `/bin/sh` or package manager; its executable `PATH` points to the Python environment. The MIT license label identifies the Docling Serve source, not a full third-party license inventory or SBOM. The build checks import the API, confirm model-weight files are absent, and exercise health/readiness/liveness locally with model loading disabled and Hugging Face offline. They do not make model requests.

No Podman import or runtime smoke test is performed as part of this package build.
