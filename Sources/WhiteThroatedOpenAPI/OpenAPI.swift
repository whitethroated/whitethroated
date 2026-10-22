import Foundation
import WhiteThroated
import WhiteThroatedValidation

public enum OpenAPIRegistryError:
    Error,
    Sendable,
    Equatable
{
    case invalidPath(String)
    case duplicateRoute(
        method: String,
        path: String
    )
    case duplicateOperationID(String)
    case unsupportedMethod(String)
    case optionalPathParameter(String)
    case unknownPathParameter(String)
    case missingPathParameterValidation(String)
}

public struct OpenAPIInfo:
    Sendable,
    Equatable,
    Encodable
{
    public let title: String
    public let version: String
    public let description: String?

    public init(
        title: String,
        version: String,
        description: String? = nil
    ) {
        precondition(
            !title.isEmpty,
            "OpenAPI title must not be empty"
        )
        precondition(
            !version.isEmpty,
            "OpenAPI version must not be empty"
        )

        self.title = title
        self.version = version
        self.description = description
    }
}

public indirect enum OpenAPISchema:
    Sendable,
    Equatable,
    Encodable
{
    case string(
        format: String? = nil,
        allowedValues: [String]? = nil
    )
    case integer(
        format: String? = nil
    )
    case number(
        format: String? = nil
    )
    case boolean
    case array(
        items: OpenAPISchema
    )
    case object(
        properties:
            [String: OpenAPISchema],
        required: [String] = []
    )

    private enum CodingKeys:
        String,
        CodingKey
    {
        case type
        case format
        case enumValues = "enum"
        case items
        case properties
        case required
    }

    public func encode(
        to encoder: Encoder
    ) throws {
        var container =
            encoder.container(
                keyedBy:
                    CodingKeys.self
            )

        switch self {
        case .string(
            let format,
            let allowedValues
        ):
            try container.encode(
                "string",
                forKey: .type
            )
            try container.encodeIfPresent(
                format,
                forKey: .format
            )
            try container.encodeIfPresent(
                allowedValues,
                forKey: .enumValues
            )

        case .integer(let format):
            try container.encode(
                "integer",
                forKey: .type
            )
            try container.encodeIfPresent(
                format,
                forKey: .format
            )

        case .number(let format):
            try container.encode(
                "number",
                forKey: .type
            )
            try container.encodeIfPresent(
                format,
                forKey: .format
            )

        case .boolean:
            try container.encode(
                "boolean",
                forKey: .type
            )

        case .array(let items):
            try container.encode(
                "array",
                forKey: .type
            )
            try container.encode(
                items,
                forKey: .items
            )

        case .object(
            let properties,
            let required
        ):
            try container.encode(
                "object",
                forKey: .type
            )
            try container.encode(
                properties,
                forKey: .properties
            )

            if !required.isEmpty {
                try container.encode(
                    required.sorted(),
                    forKey: .required
                )
            }
        }
    }
}

public struct OpenAPIJSONBody:
    Sendable,
    Equatable
{
    public let schema: OpenAPISchema
    public let required: Bool
    public let limits:
        JSONValidationLimits

    public init(
        schema: OpenAPISchema,
        required: Bool = true,
        limits:
            JSONValidationLimits =
                .default
    ) {
        self.schema = schema
        self.required = required
        self.limits = limits
    }
}

public struct OpenAPIResponse:
    Sendable,
    Equatable
{
    public let description: String
    public let schema:
        OpenAPISchema?

    public init(
        description: String,
        schema: OpenAPISchema? = nil
    ) {
        precondition(
            !description.isEmpty,
            "OpenAPI response description must not be empty"
        )

        self.description = description
        self.schema = schema
    }
}

public struct OpenAPIOperation:
    Sendable
{
    public let operationID: String
    public let summary: String?
    public let description: String?
    public let tags: [String]
    public let validation:
        ValidationSchema?
    public let jsonBody:
        OpenAPIJSONBody?
    public let responses:
        [String: OpenAPIResponse]

    public init(
        operationID: String,
        summary: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        validation:
            ValidationSchema? = nil,
        jsonBody:
            OpenAPIJSONBody? = nil,
        responses:
            [String: OpenAPIResponse] = [
                "200":
                    OpenAPIResponse(
                        description: "Success"
                    ),
            ]
    ) {
        precondition(
            !operationID.isEmpty,
            "OpenAPI operationID must not be empty"
        )
        precondition(
            !responses.isEmpty,
            "OpenAPI operation must document at least one response"
        )

        self.operationID = operationID
        self.summary = summary
        self.description = description
        self.tags = tags
        self.validation = validation
        self.jsonBody = jsonBody
        self.responses = responses
    }
}

private struct OpenAPIRouteKey:
    Sendable,
    Hashable
{
    let method: String
    let path: String
}

private struct OpenAPIRegistration:
    Sendable
{
    let method: String
    let sourcePath: String
    let documentPath: String
    let operation: OpenAPIOperation
}

public struct OpenAPIRegistry:
    Sendable
{
    public let info: OpenAPIInfo

    private var registrations:
        [OpenAPIRouteKey:
            OpenAPIRegistration]
    private var operationIDs:
        Set<String>

    public init(info: OpenAPIInfo) {
        self.info = info
        self.registrations = [:]
        self.operationIDs = []
    }

    public mutating func register(
        _ method: HTTPMethod,
        _ path: String,
        operation:
            OpenAPIOperation
    ) throws {
        guard
            path.hasPrefix("/"),
            !path.contains("?"),
            !path.contains("#")
        else {
            throw OpenAPIRegistryError
                .invalidPath(path)
        }

        let methodName =
            try Self.methodName(method)
        let documentPath =
            try Self.documentPath(path)
        let key =
            OpenAPIRouteKey(
                method: methodName,
                path: documentPath
            )

        guard
            registrations[key] == nil
        else {
            throw OpenAPIRegistryError
                .duplicateRoute(
                    method: methodName,
                    path: documentPath
                )
        }

        guard
            operationIDs.insert(
                operation.operationID
            ).inserted
        else {
            throw OpenAPIRegistryError
                .duplicateOperationID(
                    operation.operationID
                )
        }

        do {
            try Self.validatePathFields(
                sourcePath: path,
                validation:
                    operation.validation
            )
        } catch {
            operationIDs.remove(
                operation.operationID
            )
            throw error
        }

        registrations[key] =
            OpenAPIRegistration(
                method: methodName,
                sourcePath: path,
                documentPath:
                    documentPath,
                operation: operation
            )
    }

    public func jsonData(
        prettyPrinted: Bool = true
    ) throws -> Data {
        let document =
            try makeDocument()
        let encoder = JSONEncoder()

        if prettyPrinted {
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
        } else {
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
        }

        return try encoder.encode(
            document
        )
    }

    public func yamlString()
        throws -> String
    {
        try OpenAPIYAML.encode(
            jsonData(
                prettyPrinted: false
            )
        )
    }

    fileprivate func makeDocument()
        throws -> OpenAPIDocument
    {
        var paths:
            [String:
                [String:
                    OpenAPIOperationDocument]] =
                [:]

        for registration in
            registrations.values
        {
            let operation =
                try Self.operationDocument(
                    registration
                )

            paths[
                registration.documentPath,
                default: [:]
            ][registration.method] =
                operation
        }

        return OpenAPIDocument(
            info: info,
            paths: paths
        )
    }

    private static func operationDocument(
        _ registration:
            OpenAPIRegistration
    ) throws
        -> OpenAPIOperationDocument
    {
        let operation =
            registration.operation

        let parameters =
            operation.validation?
                .fields
                .map(
                    parameterDocument
                )
            ?? []

        let requestBody =
            operation.jsonBody.map {
                OpenAPIRequestBodyDocument(
                    required: $0.required,
                    content: [
                        "application/json":
                            OpenAPIMediaTypeDocument(
                                schema:
                                    $0.schema
                            ),
                    ],
                    maxBytes:
                        $0.limits.maxBytes,
                    maxDepth:
                        $0.limits.maxDepth
                )
            }

        var responses:
            [String:
                OpenAPIResponseDocument] =
                [:]

        for (
            status,
            response
        ) in operation.responses {
            let content:
                [String:
                    OpenAPIMediaTypeDocument]?

            if let schema =
                response.schema
            {
                content = [
                    "application/json":
                        OpenAPIMediaTypeDocument(
                            schema: schema
                        ),
                ]
            } else {
                content = nil
            }

            responses[status] =
                OpenAPIResponseDocument(
                    description:
                        response.description,
                    content: content
                )
        }

        return OpenAPIOperationDocument(
            operationID:
                operation.operationID,
            summary: operation.summary,
            description:
                operation.description,
            tags:
                operation.tags.isEmpty
                ? nil
                : operation.tags,
            parameters:
                parameters.isEmpty
                ? nil
                : parameters,
            requestBody: requestBody,
            responses: responses
        )
    }

    private static func parameterDocument(
        _ field: ValidationField
    ) -> OpenAPIParameterDocument {
        var minimum: Int?
        var maximum: Int?
        var allowed: [String]?
        var custom = false

        for rule in field.rules {
            switch rule {
            case .nonEmpty:
                minimum = max(
                    minimum ?? 0,
                    1
                )

            case .minLength(
                let value
            ):
                minimum = max(
                    minimum ?? value,
                    value
                )

            case .maxLength(
                let value
            ):
                maximum = min(
                    maximum ?? value,
                    value
                )

            case .oneOf(
                let values
            ):
                allowed =
                    values.sorted()

            case .custom:
                custom = true
            }
        }

        return OpenAPIParameterDocument(
            name: field.name,
            location:
                field.location.rawValue,
            required:
                field.location == .path
                ? true
                : field.required,
            schema:
                OpenAPIStringParameterSchema(
                    minLength: minimum,
                    maxLength: maximum,
                    allowedValues: allowed,
                    hasCustomValidation:
                        custom
                )
        )
    }

    private static func validatePathFields(
        sourcePath: String,
        validation:
            ValidationSchema?
    ) throws {
        let names =
            Set(
                pathParameterNames(
                    sourcePath
                )
            )

        let fields =
            validation?.fields.filter {
                $0.location == .path
            }
            ?? []

        for field in fields {
            guard
                names.contains(
                    field.name
                )
            else {
                throw OpenAPIRegistryError
                    .unknownPathParameter(
                        field.name
                    )
            }

            guard field.required else {
                throw OpenAPIRegistryError
                    .optionalPathParameter(
                        field.name
                    )
            }
        }

        let documented =
            Set(
                fields.map(\.name)
            )

        for name in names
        where !documented.contains(name) {
            throw OpenAPIRegistryError
                .missingPathParameterValidation(
                    name
                )
        }
    }

    private static func documentPath(
        _ path: String
    ) throws -> String {
        let segments =
            path.split(
                separator: "/",
                omittingEmptySubsequences:
                    false
            )
        var output:
            [String] = []
        output.reserveCapacity(
            segments.count
        )

        for segmentSubsequence in
            segments
        {
            let segment =
                String(segmentSubsequence)

            if
                segment.hasPrefix(":")
                || segment.hasPrefix("*")
            {
                let name =
                    String(
                        segment.dropFirst()
                    )

                guard !name.isEmpty else {
                    throw OpenAPIRegistryError
                        .invalidPath(path)
                }

                output.append(
                    "{\(name)}"
                )
            } else {
                output.append(segment)
            }
        }

        return output.joined(
            separator: "/"
        )
    }

    private static func pathParameterNames(
        _ path: String
    ) -> [String] {
        path.split(
            separator: "/"
        )
        .compactMap {
            segment in

            guard
                segment.first == ":"
                || segment.first == "*"
            else {
                return nil
            }

            let name =
                segment.dropFirst()

            return name.isEmpty
                ? nil
                : String(name)
        }
    }

    private static func methodName(
        _ method: HTTPMethod
    ) throws -> String {
        switch method {
        case .get:
            return "get"
        case .post:
            return "post"
        case .put:
            return "put"
        case .patch:
            return "patch"
        case .delete:
            return "delete"
        case .head:
            return "head"
        case .options:
            return "options"
        case .trace:
            return "trace"
        case .connect:
            throw OpenAPIRegistryError
                .unsupportedMethod(
                    "CONNECT"
                )
        case .other(let value):
            throw OpenAPIRegistryError
                .unsupportedMethod(
                    value
                )
        }
    }
}

private struct OpenAPIDocument:
    Encodable
{
    let openapi = "3.1.0"
    let info: OpenAPIInfo
    let paths:
        [String:
            [String:
                OpenAPIOperationDocument]]
}

private struct OpenAPIOperationDocument:
    Encodable
{
    let operationID: String
    let summary: String?
    let description: String?
    let tags: [String]?
    let parameters:
        [OpenAPIParameterDocument]?
    let requestBody:
        OpenAPIRequestBodyDocument?
    let responses:
        [String:
            OpenAPIResponseDocument]

    private enum CodingKeys:
        String,
        CodingKey
    {
        case operationID = "operationId"
        case summary
        case description
        case tags
        case parameters
        case requestBody
        case responses
    }
}

private struct OpenAPIParameterDocument:
    Encodable
{
    let name: String
    let location: String
    let required: Bool
    let schema:
        OpenAPIStringParameterSchema

    private enum CodingKeys:
        String,
        CodingKey
    {
        case name
        case location = "in"
        case required
        case schema
    }
}

private struct OpenAPIStringParameterSchema:
    Encodable
{
    let type = "string"
    let minLength: Int?
    let maxLength: Int?
    let allowedValues: [String]?
    let hasCustomValidation: Bool

    private enum CodingKeys:
        String,
        CodingKey
    {
        case type
        case minLength
        case maxLength
        case allowedValues = "enum"
        case hasCustomValidation =
            "x-whitethroated-custom-validation"
    }

    func encode(
        to encoder: Encoder
    ) throws {
        var container =
            encoder.container(
                keyedBy:
                    CodingKeys.self
            )
        try container.encode(
            type,
            forKey: .type
        )
        try container.encodeIfPresent(
            minLength,
            forKey: .minLength
        )
        try container.encodeIfPresent(
            maxLength,
            forKey: .maxLength
        )
        try container.encodeIfPresent(
            allowedValues,
            forKey: .allowedValues
        )

        if hasCustomValidation {
            try container.encode(
                true,
                forKey:
                    .hasCustomValidation
            )
        }
    }
}

private struct OpenAPIRequestBodyDocument:
    Encodable
{
    let required: Bool
    let content:
        [String:
            OpenAPIMediaTypeDocument]
    let maxBytes: Int
    let maxDepth: Int

    private enum CodingKeys:
        String,
        CodingKey
    {
        case required
        case content
        case maxBytes =
            "x-whitethroated-max-bytes"
        case maxDepth =
            "x-whitethroated-max-depth"
    }
}

private struct OpenAPIMediaTypeDocument:
    Encodable
{
    let schema: OpenAPISchema
}

private struct OpenAPIResponseDocument:
    Encodable
{
    let description: String
    let content:
        [String:
            OpenAPIMediaTypeDocument]?
}
