# UTM Patch Stack

The clean PEGPU app repository keeps normal PEGPU code directly in this branch,
but keeps UTM/CocoaSpice-derived display changes as patches.

Base:

- Repository: https://github.com/utmapp/UTM.git
- Commit: e4a4c34b671284263fc69f81b607de494d7e9b65
- Tag: v5.0.3

Build flow:

1. `scripts/apply-utm-patches.sh` clones/checks out the pinned UTM base.
2. It applies every patch in `third_party/utm/patches`.
3. SwiftPM uses the patched CocoaSpice package from that patched UTM checkout.
4. `scripts/build-display-runtime-from-source.sh` uses the same patched UTM
   dependency recipe to build SPICE/GLib/GStreamer/ANGLE frameworks.

No generated UTM framework, app, package, or copied UTM source tree
is committed in this clean repository.
