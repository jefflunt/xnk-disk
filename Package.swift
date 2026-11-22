// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XnkDisk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "XnkDisk", targets: ["XnkDisk"]),
        .library(name: "XnkDiskCore", targets: ["XnkDiskCore"])
    ],
    targets: [
        .target(
            name: "XnkDiskCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "XnkDisk",
            dependencies: ["XnkDiskCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "XnkDiskTests",
            dependencies: ["XnkDiskCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
