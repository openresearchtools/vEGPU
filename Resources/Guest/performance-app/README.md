# PEGPU Performance

Linux guest helper for controlling the apple_dma coalescing window.

The GTK app shows friendly performance/stability presets while the root helper
installed by the apple-dma DKMS package writes the underlying kernel module
option.

## Commands

```sh
pegpu-performance --gui
pegpu-performance list --json
pegpu-performance get --json
pegpu-performance set --coalescing 256kb
pegpu-performance reset
```

Supported modes are `off`, `128kb`, `256kb`, and `512kb`.
