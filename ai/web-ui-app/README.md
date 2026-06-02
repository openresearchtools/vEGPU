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

Mutable config is stored under the vEGPU app support directory. vEGPU release
packages ship the latest llama.cpp ARM64 runtime pair available at vEGPU
release time from `openresearchtools/llama-cpp-arm64-builds`; `/core` still
lets users fetch, activate, retry, and delete additional matched runtime pairs.

## Discovery

Automatic discovery scans app-local models, Hugging Face cache, LM Studio, and llama.cpp cache. Hugging Face discovery is GGUF-only: files must have a `.gguf` snapshot filename and a `GGUF` file header, so MLX repos in the same cache are ignored. Ollama manifest/blob resolution is intentionally disabled.

## Runtime

Release packages include one bundled llama.cpp runtime release: macOS ARM64,
Debian Trixie CUDA 13 ARM64, and Debian Trixie Vulkan ARM64. On first app
startup, the bundled release is installed into the normal managed runtime
folders; CUDA is selected by default and Vulkan remains installed for later
selection. On first VM boot, the seed bundle installs the Linux CUDA and Vulkan
runtimes under `/home/vegpu/custom-llama-runtimes`.

`/core` also installs matched macOS and Linux runtime pairs from
`openresearchtools/llama-cpp-arm64-builds` releases. Users choose the runtime
family (`llama.cpp` or TurboQuant), release tag, and Linux backend (`CUDA 13`
by default or `Vulkan`). Each pair is kept in its own runtime folder, so users
can keep multiple matched versions, activate one pair at a time, and delete
inactive pairs to reclaim space. macOS selection points the router at the
extracted `llama-server`; Linux VM selection installs/switches
`/usr/local/bin/llama-server` and `/usr/local/bin/rpc-server` wrappers to the
matching release.

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
