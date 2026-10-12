// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "GlassesBridge",
  platforms: [
    // DAT 1.0.0 binaries are built with -target arm64-apple-ios17.2
    .iOS("17.2"),
  ],
  products: [
    // An xtool project contains exactly one library product: the app itself.
    .library(name: "GlassesBridge", targets: ["GlassesBridge"]),
  ],
  dependencies: [
    .package(url: "https://github.com/facebook/meta-wearables-dat-ios", exact: "1.0.0"),
  ],
  targets: [
    .target(
      name: "GlassesBridge",
      dependencies: [
        .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
        .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
      ]
    ),
  ]
)
