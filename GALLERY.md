# PEGPU Gallery

[Back to README](README.md)

## GUI

![PEGPU GUI display view with Linux desktop, host metrics, VM metrics, and NVIDIA GPU status.](website/assets/slides/gui.webp)

The internal Linux desktop is rendered inside the macOS app through the UTM-derived SPICE, ANGLE, and CocoaSpice path, so setup and normal GUI work stay accelerated without using the passed-through NVIDIA card for the desktop.

## External Displays

![PEGPU GUI tab context menu showing external display session shortcuts for NVIDIA eGPUs.](website/assets/slides/external-display.webp)

Secondary-click in the GUI tab to turn on external display sessions on eGPUs. There is no fixed limit: each GPU has its own external display session, and every monitor connected to that GPU shares the same session so Linux/NVIDIA settings can extend or mirror them. Move into a session with the app-shown shortcuts for that GPU, from `⌥⌘2` through `⌥⌘9`; `⌥⌘1` always releases control back to the Mac. The main Mac-driven GUI does not lock the pointer because it uses absolute mouse mirroring directly on the screen.

## Runtime

![PEGPU Runtime view showing server controls and runtime status.](website/assets/slides/runtime.webp)

The Runtime view starts and stops the PEGPU Machine server, shows whether the VM/control routes are alive, and keeps Mac, guest, network, disk, and VM GPU telemetry in one place. It also launches the recipe-based Debian setup and NVIDIA/CUDA helper install flow, because the download does not ship a bundled VM or preinstalled GPU driver stack.

## Models

![PEGPU Models view for local model and runtime management.](website/assets/slides/models.webp)

The Models view manages model files and llama.cpp launches. Pick the Mac backend, the Linux/eGPU backend, or a split run where llama.cpp RPC bridges host and guest; TurboQuant is only the optional llama.cpp build/flag path for KV-cache quantization, not a separate GPU target. The UI assembles the real launch details: devices, RPC endpoint, GPU layers, tensor split, and cache type.

> **Tip:** Models does not repeatedly probe SSH for devices. With the VM running and GPU passthrough active, click Refresh Devices once to surface all connected GPUs.

## Chat

![PEGPU Chat view for local AI runtime interaction.](website/assets/slides/chat.webp)

The Chat tab talks to the currently loaded model through the local OpenAI-compatible route. It is there to test the selected model, backend, and split inference path from inside PEGPU before you point another app at the same runtime.

## Files

![PEGPU Files view for browsing shared Mac and Linux files.](website/assets/slides/files.webp)

The Files tab is a two-pane Mac and Linux file manager for the shared runtime paths. It handles browsing, drag/drop copy or move, transfer jobs, mount repair, and Finder handoff, so moving models, downloads, outputs, and VM files does not require falling back to ad hoc scp commands every time.
