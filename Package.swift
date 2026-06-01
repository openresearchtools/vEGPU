// swift-tools-version: 6.0
import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let defaultBuildRoot = environment["VEGPU_BUILD_ROOT"]
    ?? environment["RUNNER_TEMP"].map { "\($0)/vegpu-build" }
    ?? "\(NSTemporaryDirectory())vegpu-build"
let cocoaSpicePackagePath = environment["VEGPU_COCOASPICE_PACKAGE_PATH"]
    ?? "\(defaultBuildRoot)/utm-patched/OpenResearchTools/CocoaSpice"
let displayFrameworksPath = environment["VEGPU_DISPLAY_FRAMEWORKS_OUT"]
    ?? environment["VEGPU_DISPLAY_FRAMEWORKS_DIR"]
    ?? "\(defaultBuildRoot)/display-frameworks/macos-arm64"

let package = Package(
    name: "vEGPU-Swift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "vEGPUCore", targets: ["vEGPUCore"]),
        .executable(name: "vEGPUApp", targets: ["vEGPUApp"]),
        .executable(name: "vegpu", targets: ["vegpu"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        .package(path: cocoaSpicePackagePath)
    ],
    targets: [
        .target(
            name: "vEGPUCore",
            dependencies: []
        ),
        .executableTarget(
            name: "vEGPUApp",
            dependencies: [
                "vEGPUCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CocoaSpiceNoUsb", package: "CocoaSpice")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(displayFrameworksPath)",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                    "-framework", "spice-client-glib-2.0.8",
                    "-framework", "glib-2.0.0",
                    "-framework", "gobject-2.0.0",
                    "-framework", "gmodule-2.0.0",
                    "-framework", "gthread-2.0.0",
                    "-framework", "gio-2.0.0",
                    "-framework", "gstreamer-1.0.0",
                    "-framework", "gstbase-1.0.0",
                    "-framework", "gstaudio-1.0.0",
                    "-framework", "gstapp-1.0.0",
                    "-framework", "gstallocators-1.0.0",
                    "-framework", "gstpbutils-1.0.0",
                    "-framework", "gstvideo-1.0.0",
                    "-framework", "gsttag-1.0.0",
                    "-framework", "gstriff-1.0.0",
                    "-framework", "gstrtp-1.0.0",
                    "-framework", "gstrtsp-1.0.0",
                    "-framework", "gstsdp-1.0.0",
                    "-framework", "gstfft-1.0.0",
                    "-framework", "gstnet-1.0.0",
                    "-framework", "json-glib-1.0.0",
                    "-framework", "soup-3.0.0",
                    "-framework", "phodav-3.0.0",
                    "-framework", "pixman-1.0",
                    "-framework", "intl.8",
                    "-framework", "ffi.8",
                    "-framework", "zstd.1",
                    "-framework", "png16.16",
                    "-framework", "jpeg.62",
                    "-framework", "gcrypt.20",
                    "-framework", "gpg-error.0",
                    "-framework", "ssl.1.1",
                    "-framework", "crypto.1.1",
                    "-framework", "opus.0"
                ])
            ]
        ),
        .executableTarget(
            name: "vegpu",
            dependencies: ["vEGPUCore"]
        )
    ]
)
