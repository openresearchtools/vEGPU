# web-ui-app

Single-binary llama.cpp web UI wrapper with a llama-swap-style router backend.

## Run

```sh
go build -o "${TMPDIR:-/tmp}/vegpu-build/web-ui-app" .
"${TMPDIR:-/tmp}/vegpu-build/web-ui-app"
```

The app serves:

- `http://127.0.0.1:9292/` - embedded llama.cpp chat UI
- `http://127.0.0.1:9292/core` - standalone router, model, device, and runtime settings

Mutable config is `app.yaml` beside the binary. Runtime binaries are not bundled; install a matched pair from `/core` before loading models.

## Discovery

Automatic discovery scans app-local models, Hugging Face cache, LM Studio, and llama.cpp cache. Hugging Face discovery is GGUF-only: files must have a `.gguf` snapshot filename and a `GGUF` file header, so MLX repos in the same cache are ignored. Ollama manifest/blob resolution is intentionally disabled.

## Runtime

`/core` installs matched macOS and Linux runtime pairs from `openresearchtools/llama-cpp-arm64-builds` releases. Users choose the runtime family (`llama.cpp` or TurboQuant), release tag, and Linux backend (`CUDA 13` by default or `Vulkan`). Each pair is kept in its own runtime folder, so users can keep multiple matched versions, activate one pair at a time, and delete inactive pairs to reclaim space. macOS selection points the router at the extracted `llama-server`; Linux VM selection installs/switches `/usr/local/bin/llama-server` and `/usr/local/bin/rpc-server` wrappers to the matching release.

The runtime flag catalog is parsed from the selected release runtime when it exists, with conservative fallback flags when it does not.

## Router Endpoints

The app exposes llama.cpp/OpenAI-compatible model routing:

- `GET /v1/models`
- `GET /models`
- `POST /models/load`
- `POST /models/unload`
- `GET /props?model=...`
- `GET /slots?model=...`
- JSON body routed llama.cpp APIs such as `/v1/chat/completions`, `/v1/responses`, `/v1/embeddings`, `/v1/rerank`, `/completion`, and `/rerank`

Requests are routed by the JSON `model` field. Only one model is active by default, with per-model TTL unload support.

## Admin APIs

- `GET /api/config`
- `PATCH /api/config`
- `PATCH /api/models/:id`
- `DELETE /api/models/:id`
- `POST /api/models/refresh`
- `GET /api/runtime/status`
- `GET /api/runtime/flags`
- `GET /api/runtimes`
- `GET /api/runtimes/releases`
- `POST /api/runtimes/fetch-install`
- `POST /api/runtimes/pair/activate`
- `POST /api/runtimes/pair/delete`
- `POST /api/runtimes/install`
- `POST /api/runtimes/activate`
- `POST /api/runtimes/delete`
- `GET /api/devices`
- `GET /api/hf/tree`
- `POST /api/hf/download`
- `GET /api/hf/downloads`
