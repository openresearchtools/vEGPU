# Known Issues

## NVIDIA Blackwell (GB202) cards — SPTM DART kernel panic on M-series

### Affected hardware

| Component | Details |
| --- | --- |
| GPU | NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition (PCI `10de:2bb4`, 96 GB) |
| Host | Mac Studio M3 Ultra (Mac15,14), macOS 26.x |
| Enclosure | Thunderbolt 5 (80 Gb/s) eGPU enclosure |
| PEGPU | app 0.1.106, Machine / `com.pegpu.machine.VFIOUserPCIDriver` 0.1.105 |
| Guest | Debian 13 (trixie) aarch64, kernel 6.12, `apple-dma` 0.1.105 |

### Symptom

The Mac hard-panics (SoC watchdog power-off) every time the NVIDIA driver
performs real BAR/DMA I/O against the passed-through GPU — for example driver
auto-probe at guest boot, or `nvidia-smi` / NVML init.

The panic is identical on every occurrence:

```
panic(cpu N caller ...): [SPTM] VIOLATION_T8110_DART_INVALID_ERR_MASK:
validate_t8110dart_err_mask(t8110dart_validation.h:324)
state->dart_id(0xd), err_mask(0x80180000)
```

Kernel extensions in the backtrace:

```
com.apple.sptm(25.6)
com.apple.driver.AppleT8110DART(1.0)
  -> com.apple.driver.AppleARMPlatform(1.0.2)
  -> com.apple.driver.IODARTFamily(1)
```

`err_mask 0x80180000` decodes to fatal read **and** write translation faults.
DART `dart_id 0xd` is the Thunderbolt PCIe tunnel.

### What works

- GPU passthrough itself is stable: the VM boots, the card is visible at guest
  `00:1e.0`, and the desktop / SSH / GUI all work.
- The NVIDIA kernel module **loads** without panicking.
- The panic only fires once RM maps the Blackwell BARs for real I/O.

### What does not work

- `nvidia-smi` / CUDA / any real GPU compute against the passed-through card.

### Workaround

Blacklist the NVIDIA driver in the guest to run the VM with the GPU visible but
not driven:

```sh
cat > /etc/modprobe.d/nvidia-blacklist.conf << 'EOF'
blacklist nvidia
blacklist nvidia-drm
blacklist nvidia-modeset
blacklist nvidia-uvm
EOF
sudo update-initramfs -u
```

This stops the panic (useful for display/desktop use), but the card cannot be
used for CUDA until the DART issue is fixed.

### Attempted fixes (no change)

- `apple_dma window_shift=17` and `window_shift=0` (disable coalescing)
- `enable_quirks` on / off
- NVIDIA driver `595.71.05`, `595.91.07`, and `610.57.04`

### Status

Underlying cause is the Apple T8110 DART rejecting the large-BAR / DMA mappings
Blackwell requires; SPTM treats the resulting DART error state as a security
violation. Tracked upstream:

- [scottjg/qemu-vfio-apple#9](https://github.com/scottjg/qemu-vfio-apple/issues/9)
- [scottjg/qemu-vfio-apple#5](https://github.com/scottjg/qemu-vfio-apple/issues/5)
- [tinygrad/tinygrad#16086](https://github.com/tinygrad/tinygrad/issues/16086)
  (RTX PRO 5000 Blackwell, identical panic)

No fix is available as of this writing. Cards validated by PEGPU to date
(3090 / 5070 Ti) do not hit this limit.
