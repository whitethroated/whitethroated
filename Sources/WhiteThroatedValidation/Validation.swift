import Foundation
import NIOCore
import WhiteThroated

public enum ValidationLocation: String, Sendable, Hashable {
    case path
    case query
    case header
    case cookie
    case body
}

public enum ValidationIssueCode: String, Sendable, Hashable {
    case missing
    case empty
    case tooShort
    case tooLong
    case notAllowed
    case predicateFailed
    case bodyTooLarge
    case bodyTooDeep
    case malformedBody
}

public struct ValidationIssue: Error, Sendable, Equatable {
    public let location: ValidationLocation
    public let field: String?
    public let code: ValidationIssueCode
    public let message: String

    public init(
        location: ValidationLocation,
        field: String? = nil,
        code: ValidationIssueCode,
        message: String
    ) {
        self.location = location
        self.field = field
        self.code = code
        self.message = message
    }
}

public struct ValidationFailure: Error, Sendable, Equatable {
    public let issues: [ValidationIssue]

    public init(issues: [ValidationIssue]) {
        precondition(
            !issues.isEmpty,
            "ValidationFailure requires at least one issue"
        )
        self.issues = issues
    }
}

public enum StringValidationRule: Sendable {
    case nonEmpty
    case minLength(Int)
    case maxLength(Int)
    case oneOf(Set<String>)
    case custom(
        code: ValidationIssueCode,
        message: String,
        predicate: @Sendable (String) -> Bool
    )
}

public struct ValidationField: Sendable {
    public let location: ValidationLocation
    public let name: String
    public let required: Bool
    public let rules: [StringValidationRule]

    public init(
        location: ValidationLocation,
        name: String,
        required: Bool = true,
        rules: [StringValidationRule] = []
    ) {
        precondition(
            location != .body,
            "Use JSONValidationLimits for request body validation"
        )
        precondition(
            !name.isEmpty,
            "Validation field name must not be empty"
        )

        for rule in rules {
            switch rule {
            case .minLength(let length),
                 .maxLength(let length):
                precondition(
                    length >= 0,
                    "Validation string lengths must be zero or greater"
                )

            case .nonEmpty,
                 .oneOf,
                 .custom:
                break
            }
        }

        self.location = location
        self.name = name
        self.required = required
        self.rules = rules
    }

    public static func path(
        _ name: String,
        required: Bool = true,
        rules: [StringValidationRule] = []
    ) -> ValidationField {
        ValidationField(
            location: .path,
            name: name,
            required: required,
            rules: rules
        )
    }

    public static func query(
        _ name: String,
        required: Bool = true,
        rules: [StringValidationRule] = []
    ) -> ValidationField {
        ValidationField(
            location: .query,
            name: name,
            required: required,
            rules: rules
        )
    }

    public static func header(
        _ name: String,
        required: Bool = true,
        rules: [StringValidationRule] = []
    ) -> ValidationField {
        ValidationField(
            location: .header,
            name: name,
            required: required,
            rules: rules
        )
    }

    public static func cookie(
        _ name: String,
        required: Bool = true,
        rules: [StringValidationRule] = []
    ) -> ValidationField {
        ValidationField(
            location: .cookie,
            name: name,
            required: required,
            rules: rules
        )
    }
}

public struct ValidationFieldKey: Sendable, Hashable {
    public let location: ValidationLocation
    public let name: String

    public init(
        location: ValidationLocation,
        name: String
    ) {
        self.location = location
        self.name = name
    }
}

public struct ValidationValues: Sendable {
    private let storage: [ValidationFieldKey: String]

    init(storage: [ValidationFieldKey: String]) {
        self.storage = storage
    }

    public subscript(
        location: ValidationLocation,
        name: String
    ) -> String? {
        storage[
            ValidationFieldKey(
                location: location,
                name: name
            )
        ]
    }

    public func value(
        for field: ValidationField
    ) -> String? {
        self[
            field.location,
            field.name
        ]
    }
}

public struct ValidationResult: Sendable {
    public let values: ValidationValues
    public let issues: [ValidationIssue]

    public var isValid: Bool {
        issues.isEmpty
    }

    public func get() throws -> ValidationValues {
        guard issues.isEmpty else {
            throw ValidationFailure(
                issues: issues
            )
        }

        return values
    }
}

public struct ValidationSchema: Sendable {
    public let fields: [ValidationField]

    public init(
        fields: [ValidationField]
    ) {
        var keys = Set<ValidationFieldKey>()
        keys.reserveCapacity(fields.count)

        for field in fields {
            let inserted = keys.insert(
                ValidationFieldKey(
                    location: field.location,
                    name: field.name
                )
            )

            precondition(
                inserted.inserted,
                "Validation schema contains a duplicate field"
            )
        }

        self.fields = fields
    }

    /// Validates every field in order. Query fields resolve through
    /// `request.queryParameters` — the same request space handlers
    /// read — so a duplicated key is judged as its last occurrence.
    /// Path, header, and cookie fields resolve through the request's
    /// lazy accessors.
    public func validate(
        _ request: Request
    ) -> ValidationResult {
        var values: [
            ValidationFieldKey: String
        ] = [:]
        values.reserveCapacity(fields.count)

        var issues: [ValidationIssue] = []

        var queryValues: [String: String]?

        for field in fields {
            let value = value(
                for: field,
                in: request,
                queryValues:
                    &queryValues
            )

            guard let value else {
                if field.required {
                    issues.append(
                        ValidationIssue(
                            location: field.location,
                            field: field.name,
                            code: .missing,
                            message:
                                "Required field is missing"
                        )
                    )
                }
                continue
            }

            let key = ValidationFieldKey(
                location: field.location,
                name: field.name
            )
            values[key] = value

            appendIssues(
                for: value,
                field: field,
                to: &issues
            )
        }

        return ValidationResult(
            values: ValidationValues(
                storage: values
            ),
            issues: issues
        )
    }

    private func value(
        for field: ValidationField,
        in request: Request,
        queryValues: inout [String: String]?
    ) -> String? {
        switch field.location {
        case .path:
            return request.parameter(field.name)

        case .query:
            if queryValues == nil {
                queryValues =
                    request.queryParameters
            }

            return queryValues?[field.name]

        case .header:
            return request.header(field.name)

        case .cookie:
            return request.cookie(field.name)

        case .body:
            return nil
        }
    }

    private func appendIssues(
        for value: String,
        field: ValidationField,
        to issues: inout [ValidationIssue]
    ) {
        for rule in field.rules {
            switch rule {
            case .nonEmpty:
                if value.isEmpty {
                    issues.append(
                        issue(
                            field: field,
                            code: .empty,
                            message:
                                "Field must not be empty"
                        )
                    )
                }

            case .minLength(let minimum):
                if value.count < minimum {
                    issues.append(
                        issue(
                            field: field,
                            code: .tooShort,
                            message:
                                "Field is shorter than the minimum length"
                        )
                    )
                }

            case .maxLength(let maximum):
                if value.count > maximum {
                    issues.append(
                        issue(
                            field: field,
                            code: .tooLong,
                            message:
                                "Field is longer than the maximum length"
                        )
                    )
                }

            case .oneOf(let allowed):
                if !allowed.contains(value) {
                    issues.append(
                        issue(
                            field: field,
                            code: .notAllowed,
                            message:
                                "Field contains a value that is not allowed"
                        )
                    )
                }

            case .custom(
                let code,
                let message,
                let predicate
            ):
                if !predicate(value) {
                    issues.append(
                        issue(
                            field: field,
                            code: code,
                            message: message
                        )
                    )
                }
            }
        }
    }

    private func issue(
        field: ValidationField,
        code: ValidationIssueCode,
        message: String
    ) -> ValidationIssue {
        ValidationIssue(
            location: field.location,
            field: field.name,
            code: code,
            message: message
        )
    }
}

public struct JSONValidationLimits: Sendable, Equatable {
    public let maxBytes: Int
    public let maxDepth: Int

    public init(
        maxBytes: Int = 1_048_576,
        maxDepth: Int = 64
    ) {
        precondition(
            maxBytes >= 0,
            "JSON maxBytes must be zero or greater"
        )
        precondition(
            maxDepth > 0,
            "JSON maxDepth must be greater than zero"
        )

        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
    }

    public static let `default` =
        JSONValidationLimits()
}

public extension Request {
    func validate(
        _ schema: ValidationSchema
    ) -> ValidationResult {
        schema.validate(self)
    }

    func decodeValidatedJSON<T: Decodable>(
        _ type: T.Type = T.self,
        limits: JSONValidationLimits = .default,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        let readableBytes = body.readableBytes

        guard readableBytes > 0 else {
            throw ValidationFailure(
                issues: [
                    ValidationIssue(
                        location: .body,
                        code: .missing,
                        message:
                            "Request body is empty"
                    )
                ]
            )
        }

        guard readableBytes <= limits.maxBytes else {
            throw ValidationFailure(
                issues: [
                    ValidationIssue(
                        location: .body,
                        code: .bodyTooLarge,
                        message:
                            "Request body exceeds the configured byte limit"
                    )
                ]
            )
        }

        guard
            !JSONDepthScanner.exceedsLimit(
                body.readableBytesView,
                limit: limits.maxDepth
            )
        else {
            throw ValidationFailure(
                issues: [
                    ValidationIssue(
                        location: .body,
                        code: .bodyTooDeep,
                        message:
                            "JSON nesting exceeds the configured depth limit"
                    )
                ]
            )
        }

        do {
            return try decodeJSON(
                type,
                decoder: decoder
            )
        } catch let failure as ValidationFailure {
            throw failure
        } catch {
            throw ValidationFailure(
                issues: [
                    ValidationIssue(
                        location: .body,
                        code: .malformedBody,
                        message:
                            "Request body is not valid JSON for the expected type"
                    )
                ]
            )
        }
    }
}

private enum JSONDepthScanner {
    static func exceedsLimit(
        _ bytes: ByteBufferView,
        limit: Int
    ) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false

        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                    continue
                }

                if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }

                continue
            }

            switch byte {
            case 34:
                inString = true

            case 91, 123:
                depth += 1

                if depth > limit {
                    return true
                }

            case 93, 125:
                if depth > 0 {
                    depth -= 1
                }

            default:
                continue
            }
        }

        return false
    }
}
