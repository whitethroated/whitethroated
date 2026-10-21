import Foundation
import XCTest

final class RepositoryLanguagePolicyTests: XCTestCase {
    func testRepositoryContainsNoNonSwiftSourceFiles() throws {
        let repositoryRoot = URL(
            fileURLWithPath: #filePath
        )
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

        let forbiddenExtensions: Set<String> = [
            "bash",
            "c",
            "cc",
            "cjs",
            "cpp",
            "go",
            "h",
            "hpp",
            "java",
            "js",
            "jsx",
            "kt",
            "kts",
            "lua",
            "m",
            "mjs",
            "mm",
            "php",
            "py",
            "rb",
            "rs",
            "sh",
            "ts",
            "tsx",
            "zsh"
        ]

        let forbiddenNames: Set<String> = [
            "Dockerfile",
            "Makefile"
        ]

        // SwiftPM system-library targets require a declaration header. This is
        // not an implementation source file: it only includes the system
        // libpq interface and defines a diagnostic-field constant.
        let allowedSystemLibraryHeaders: Set<String> = [
            "Sources/CPostgres/shim.h"
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: repositoryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [
                .skipsPackageDescendants
            ]
        ) else {
            return XCTFail(
                "Could not enumerate repository files"
            )
        }

        var violations: [String] = []

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(
                forKeys: [.isDirectoryKey]
            )

            if values.isDirectory == true {
                switch fileURL.lastPathComponent {
                case ".build",
                     ".git",
                     ".swiftpm",
                     "benchmark-results":
                    enumerator.skipDescendants()
                default:
                    break
                }

                continue
            }

            let name = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            let relativePath = fileURL.path
                .replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )

            if allowedSystemLibraryHeaders.contains(relativePath) {
                continue
            }

            if
                forbiddenNames.contains(name)
                || forbiddenExtensions.contains(ext)
            {
                violations.append(relativePath)
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Non-Swift source files found: "
                + violations.sorted().joined(
                    separator: ", "
                )
        )
    }
}
