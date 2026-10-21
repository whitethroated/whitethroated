import Foundation
import NIOCore
import NIOFileSystem
import NIOHTTP1
import WhiteThroated

public struct StaticFileOptions: Sendable {
    public var indexFile: String?
    public var cacheControl: String?
    public var generateETag: Bool
    public var mimeTypes: [String: String]

    public init(
        indexFile: String? = nil,
        cacheControl: String? = nil,
        generateETag: Bool = true,
        mimeTypes: [String: String] = [:]
    ) {
        if let indexFile {
            precondition(
                StaticFilePath.isSafeSingleComponent(indexFile),
                "indexFile must be a single safe path component"
            )
        }

        self.indexFile = indexFile
        self.cacheControl = cacheControl
        self.generateETag = generateETag

        var normalizedMIMETypes: [String: String] = [:]
        normalizedMIMETypes.reserveCapacity(
            mimeTypes.count
        )

        for (fileExtension, contentType) in mimeTypes {
            normalizedMIMETypes[
                fileExtension.lowercased()
            ] = contentType
        }

        self.mimeTypes = normalizedMIMETypes
    }

    public static var production: StaticFileOptions {
        StaticFileOptions(
            cacheControl: "public, max-age=3600"
        )
    }
}

public final class StaticFiles: @unchecked Sendable {
    private let root: DirectoryFileHandle
    private let options: StaticFileOptions

    private init(
        root: DirectoryFileHandle,
        options: StaticFileOptions
    ) {
        self.root = root
        self.options = options
    }

    public static func open(
        directory: String,
        options: StaticFileOptions = StaticFileOptions()
    ) async throws -> StaticFiles {
        let root = try await FileSystem.shared.openDirectory(
            atPath: FilePath(directory),
            options: OpenOptions.Directory(
                followSymbolicLinks: false,
                closeOnExec: true
            )
        )

        return StaticFiles(
            root: root,
            options: options
        )
    }

    public func close() async throws {
        try await root.close()
    }

    func response(
        for request: Request,
        mountPath: String
    ) async -> Response {
        guard
            let components = StaticFilePath.components(
                requestPath: request.path,
                mountPath: mountPath,
                indexFile: options.indexFile
            )
        else {
            return .notFound()
        }

        guard !components.isEmpty else {
            return .notFound()
        }

        let opened: OpenedStaticFile

        do {
            opened = try await openFile(
                components: components
            )
        } catch {
            return response(forFileError: error)
        }

        let totalLength = opened.length
        let entityTag =
            options.generateETag
            ? Self.entityTag(for: opened.info)
            : nil

        if
            let entityTag,
            request.matchesIfNoneMatch(entityTag)
        {
            opened.close()
            return decorate(
                .notModified(etag: entityTag)
            )
        }

        if request.method == .head {
            opened.close()

            var response = Response.stream(
                contentType: contentType(
                    for: components.last!
                ),
                contentLength: totalLength,
                status: .ok
            ) { writer in
                writer.eventLoop.makeSucceededVoidFuture()
            }

            response.setHeader(
                "accept-ranges",
                "bytes"
            )

            if let entityTag {
                response.setETag(entityTag)
            }

            return decorate(response)
        }

        let selectedRange: Range<Int>
        let status: HTTPResponseStatus
        var contentRange: String?

        let byteRange: ByteRangeResult

        if request.header("if-range") == nil {
            byteRange = request.byteRange(
                totalLength: totalLength
            )
        } else {
            // If-Range is not implemented in this experimental
            // slice. Serving the complete representation is the
            // conservative fallback; never send a potentially stale
            // partial body while ignoring its validator.
            byteRange = .none
        }

        switch byteRange {
        case .satisfiable(let range):
            selectedRange = range
            status = .partialContent
            contentRange =
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalLength)"

        case .unsatisfiable:
            opened.close()

            var response = Response
                .rangeNotSatisfiable(
                    totalLength: totalLength
                )

            if let entityTag {
                response.setETag(entityTag)
            }

            return decorate(response)

        case .none,
             .malformed,
             .unsupportedMultiple,
             .unsupportedUnit:
            selectedRange = 0..<totalLength
            status = .ok
        }

        if totalLength == 0 {
            opened.close()

            var response = Response.stream(
                contentType: contentType(
                    for: components.last!
                ),
                contentLength: 0,
                status: .ok
            ) { writer in
                writer.eventLoop.makeSucceededVoidFuture()
            }

            response.setHeader(
                "accept-ranges",
                "bytes"
            )

            if let entityTag {
                response.setETag(entityTag)
            }

            return decorate(response)
        }

        let response = makeFileResponse(
            opened,
            fileName: components.last!,
            range: selectedRange,
            status: status,
            contentRange: contentRange,
            entityTag: entityTag
        )

        return decorate(response)
    }

    private func makeFileResponse(
        _ opened: OpenedStaticFile,
        fileName: String,
        range: Range<Int>,
        status: HTTPResponseStatus,
        contentRange: String?,
        entityTag: EntityTag?
    ) -> Response {
        let region = FileRegion(
            fileHandle: opened.handle,
            readerIndex: range.lowerBound,
            endIndex: range.upperBound
        )

        var response = Response.stream(
            contentType: contentType(
                for: fileName
            ),
            contentLength: range.count,
            status: status,
            onError: { _ in
                opened.close()
            }
        ) { writer in
            let future =
                writer.writeFileRegionAndFlush(
                    region
                )

            future.whenComplete { _ in
                opened.close()
            }

            return future
        }

        response.setHeader(
            "accept-ranges",
            "bytes"
        )

        if let contentRange {
            response.setHeader(
                "content-range",
                contentRange
            )
        }

        if let entityTag {
            response.setETag(entityTag)
        }

        return response
    }

    private func decorate(
        _ response: Response
    ) -> Response {
        guard let cacheControl = options.cacheControl else {
            return response
        }

        return response.header(
            "cache-control",
            cacheControl
        )
    }

    private func contentType(
        for fileName: String
    ) -> String {
        guard
            let dot = fileName.lastIndex(of: "."),
            dot != fileName.index(
                before: fileName.endIndex
            )
        else {
            return "application/octet-stream"
        }

        let extensionStart =
            fileName.index(after: dot)
        let ext = fileName[
            extensionStart...
        ].lowercased()

        if let custom = options.mimeTypes[ext] {
            return custom
        }

        return StaticMIME.defaultType(
            for: ext
        )
    }

    private func openFile(
        components: [String]
    ) async throws -> OpenedStaticFile {
        var current = root
        var openedDirectories:
            [DirectoryFileHandle] = []

        do {
            if components.count > 1 {
                for component in components.dropLast() {
                    let next =
                        try await current.openDirectory(
                            atPath: FilePath(component),
                            options:
                                OpenOptions.Directory(
                                    followSymbolicLinks: false,
                                    closeOnExec: true
                                )
                        )

                    openedDirectories.append(
                        next
                    )
                    current = next
                }
            }

            let file = try await current.openFile(
                forReadingAt:
                    FilePath(components.last!),
                options: OpenOptions.Read(
                    followSymbolicLinks: false,
                    closeOnExec: true
                )
            )

            for directory in
                openedDirectories.reversed()
            {
                try? await directory.close()
            }

            let info = try await file.info()

            guard info.type == .regular else {
                try? await file.close()
                throw StaticFileOpenError.notRegular
            }

            guard
                info.size >= 0,
                let length = Int(
                    exactly: info.size
                )
            else {
                try? await file.close()
                throw StaticFileOpenError.fileTooLarge
            }

            let descriptor =
                try file.detachUnsafeFileDescriptor()
            let handle = NIOFileHandle(
                _deprecatedTakingOwnershipOfDescriptor:
                    descriptor.rawValue
            )

            return OpenedStaticFile(
                handle: handle,
                info: info,
                length: length
            )
        } catch {
            for directory in
                openedDirectories.reversed()
            {
                try? await directory.close()
            }

            throw error
        }
    }

    private func response(
        forFileError error: Error
    ) -> Response {
        if let error =
            error as? FileSystemError
        {
            switch error.code {
            case .notFound,
                 .invalidArgument:
                return .notFound()

            case .permissionDenied:
                return .text(
                    "Forbidden",
                    status: .forbidden
                )

            default:
                return .internalServerError()
            }
        }

        if let error =
            error as? StaticFileOpenError
        {
            switch error {
            case .notRegular:
                return .notFound()

            case .fileTooLarge:
                return .text(
                    "Static file is too large",
                    status: .internalServerError
                )
            }
        }

        return .internalServerError()
    }

    private static func entityTag(
        for info: FileInfo
    ) -> EntityTag {
        let size = String(
            info.size,
            radix: 16
        )
        let seconds = String(
            info.lastDataModificationTime.seconds,
            radix: 16
        )
        let nanoseconds = String(
            info.lastDataModificationTime.nanoseconds,
            radix: 16
        )

        return .weak(
            "\(size)-\(seconds)-\(nanoseconds)"
        )
    }
}

extension Application {
    public func mountStatic(
        _ prefix: String,
        files: StaticFiles
    ) {
        let mountPath =
            StaticFilePath.normalizedMountPath(
                prefix
            )

        let handler: AsyncHandler = {
            request in

            await files.response(
                for: request,
                mountPath: mountPath
            )
        }

        get(
            mountPath,
            use: handler
        )

        let catchAll =
            mountPath == "/"
            ? "/*path"
            : mountPath + "/*path"

        get(
            catchAll,
            use: handler
        )
    }
}

private final class OpenedStaticFile:
    @unchecked Sendable
{
    let handle: NIOFileHandle
    let info: FileInfo
    let length: Int

    init(
        handle: NIOFileHandle,
        info: FileInfo,
        length: Int
    ) {
        self.handle = handle
        self.info = info
        self.length = length
    }

    func close() {
        _ = try? handle.close()
    }

    deinit {
        if handle.isOpen {
            _ = try? handle.close()
        }
    }
}

private enum StaticFileOpenError: Error {
    case notRegular
    case fileTooLarge
}

enum StaticFilePath {
    static func normalizedMountPath(
        _ path: String
    ) -> String {
        precondition(
            path.first == "/",
            "Static mount path must start with /"
        )
        precondition(
            !path.contains("?"),
            "Static mount path cannot contain a query string"
        )
        precondition(
            !path.contains("#"),
            "Static mount path cannot contain a fragment"
        )
        precondition(
            !path.contains(":"),
            "Static mount path cannot contain route parameters"
        )
        precondition(
            !path.contains("*"),
            "Static mount path cannot contain catch-all parameters"
        )
        precondition(
            !path.contains("%"),
            "Static mount path must use literal path bytes"
        )
        precondition(
            !path.contains("\\"),
            "Static mount path cannot contain backslashes"
        )
        precondition(
            !path.contains("//"),
            "Static mount path cannot contain repeated slashes"
        )

        if path == "/" {
            return path
        }

        if path.last == "/" {
            return String(path.dropLast())
        }

        return path
    }

    static func components(
        requestPath: String,
        mountPath: String,
        indexFile: String?
    ) -> [String]? {
        let rawRelative: Substring

        if mountPath == "/" {
            guard requestPath.first == "/" else {
                return nil
            }

            rawRelative =
                requestPath.dropFirst()
        } else if requestPath == mountPath {
            rawRelative = ""
        } else {
            let prefix = mountPath + "/"

            guard requestPath.hasPrefix(prefix)
            else {
                return nil
            }

            rawRelative =
                requestPath.dropFirst(
                    prefix.count
                )
        }

        guard
            let decoded = decodeExactlyOnce(
                rawRelative
            )
        else {
            return nil
        }

        var parts = decoded.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)

        if parts.count == 1, parts[0].isEmpty {
            parts.removeAll(
                keepingCapacity: true
            )
        } else if parts.last?.isEmpty == true {
            parts.removeLast()

            guard let indexFile else {
                return nil
            }

            parts.append(indexFile)
        }

        if parts.isEmpty {
            guard let indexFile else {
                return []
            }

            parts.append(indexFile)
        }

        for part in parts {
            guard
                isSafeSingleComponent(part)
            else {
                return nil
            }
        }

        return parts
    }

    static func isSafeSingleComponent(
        _ component: String
    ) -> Bool {
        guard
            !component.isEmpty,
            component != ".",
            component != ".."
        else {
            return false
        }

        for byte in component.utf8 {
            if
                byte == 0
                || byte == 47
                || byte == 92
            {
                return false
            }
        }

        return true
    }

    private static func decodeExactlyOnce(
        _ raw: Substring
    ) -> String? {
        let bytes = Array(raw.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == 0 || byte == 92 {
                return nil
            }

            if byte != 37 {
                output.append(byte)
                index += 1
                continue
            }

            guard index + 2 < bytes.count else {
                return nil
            }

            guard
                let high = hex(bytes[index + 1]),
                let low = hex(bytes[index + 2])
            else {
                return nil
            }

            let decoded =
                (high << 4) | low

            // Encoded path separators and NUL are rejected instead
            // of being normalized into a different path structure.
            if
                decoded == 0
                || decoded == 47
                || decoded == 92
            {
                return nil
            }

            output.append(decoded)
            index += 3
        }

        return String(
            bytes: output,
            encoding: .utf8
        )
    }

    private static func hex(
        _ byte: UInt8
    ) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48

        case 65...70:
            return byte - 55

        case 97...102:
            return byte - 87

        default:
            return nil
        }
    }
}

private enum StaticMIME {
    static func defaultType(
        for ext: String
    ) -> String {
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "txt":
            return "text/plain; charset=utf-8"
        case "xml":
            return "application/xml; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        case "pdf":
            return "application/pdf"
        case "wasm":
            return "application/wasm"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        default:
            return "application/octet-stream"
        }
    }
}
