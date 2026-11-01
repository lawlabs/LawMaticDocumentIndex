// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "LawMaticDocumentIndex",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LawMaticDocumentIndex", targets: ["LawMaticDocumentIndex"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/stephencelis/SQLite.swift.git",
            from: "0.15.4"
        )
    ],
    targets: [
        .target(
            name: "LawMaticDocumentIndex",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        ),
        .testTarget(
            name: "LawMaticDocumentIndexTests",
            dependencies: [
                "LawMaticDocumentIndex",
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        )
    ]
)
