import Foundation
import XCTest
import WhiteThroated
@testable import WhiteThroatedOpenAPI
import WhiteThroatedValidation

final class OpenAPITests:
    XCTestCase
{
    func testValidationSchemaDrivesParametersAndPathTemplate() throws {
        let validation =
            ValidationSchema(
                fields: [
                    .path(
                        "id",
                        rules: [
                            .nonEmpty,
                            .minLength(2),
                            .maxLength(64),
                        ]
                    ),
                    .query(
                        "state",
                        required: false,
                        rules: [
                            .oneOf(
                                [
                                    "active",
                                    "disabled",
                                ]
                            ),
                        ]
                    ),
                    .header(
                        "x-client",
                        required: false,
                        rules: [
                            .custom(
                                code:
                                    .predicateFailed,
                                message:
                                    "custom",
                                predicate: {
                                    !$0.isEmpty
                                }
                            ),
                        ]
                    ),
                ]
            )
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "Users",
                        version: "1.0.0"
                    )
            )

        try registry.register(
            .get,
            "/users/:id",
            operation:
                OpenAPIOperation(
                    operationID:
                        "getUser",
                    validation:
                        validation
                )
        )

        let root =
            try jsonObject(
                registry
                    .jsonData(
                        prettyPrinted:
                            false
                    )
            )
        let paths =
            try XCTUnwrap(
                root["paths"]
                    as? [String: Any]
            )
        let path =
            try XCTUnwrap(
                paths[
                    "/users/{id}"
                ]
                    as? [String: Any]
            )
        let operation =
            try XCTUnwrap(
                path["get"]
                    as? [String: Any]
            )
        let parameters =
            try XCTUnwrap(
                operation[
                    "parameters"
                ]
                    as? [[String: Any]]
            )

        XCTAssertEqual(
            operation[
                "operationId"
            ] as? String,
            "getUser"
        )
        XCTAssertEqual(
            parameters.count,
            3
        )

        let id =
            try parameter(
                named: "id",
                in: parameters
            )
        XCTAssertEqual(
            id["in"] as? String,
            "path"
        )
        XCTAssertEqual(
            id["required"] as? Bool,
            true
        )

        let idSchema =
            try XCTUnwrap(
                id["schema"]
                    as? [String: Any]
            )
        XCTAssertEqual(
            idSchema[
                "minLength"
            ] as? Int,
            2
        )
        XCTAssertEqual(
            idSchema[
                "maxLength"
            ] as? Int,
            64
        )

        let state =
            try parameter(
                named: "state",
                in: parameters
            )
        let stateSchema =
            try XCTUnwrap(
                state["schema"]
                    as? [String: Any]
            )
        XCTAssertEqual(
            state["required"]
                as? Bool,
            false
        )
        XCTAssertEqual(
            stateSchema["enum"]
                as? [String],
            [
                "active",
                "disabled",
            ]
        )

        let client =
            try parameter(
                named: "x-client",
                in: parameters
            )
        let clientSchema =
            try XCTUnwrap(
                client["schema"]
                    as? [String: Any]
            )
        XCTAssertEqual(
            clientSchema[
                "x-whitethroated-custom-validation"
            ] as? Bool,
            true
        )
    }

    func testDuplicateRouteAndOperationIDAreRejected() throws {
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "API",
                        version: "1"
                    )
            )

        try registry.register(
            .get,
            "/a",
            operation:
                OpenAPIOperation(
                    operationID: "a"
                )
        )

        XCTAssertThrowsError(
            try registry.register(
                .get,
                "/a",
                operation:
                    OpenAPIOperation(
                        operationID: "b"
                    )
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    OpenAPIRegistryError,
                .duplicateRoute(
                    method: "get",
                    path: "/a"
                )
            )
        }

        XCTAssertThrowsError(
            try registry.register(
                .post,
                "/b",
                operation:
                    OpenAPIOperation(
                        operationID: "a"
                    )
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    OpenAPIRegistryError,
                .duplicateOperationID("a")
            )
        }
    }

    func testPathValidationMustBeRequiredAndMatchRoute() throws {
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "API",
                        version: "1"
                    )
            )

        XCTAssertThrowsError(
            try registry.register(
                .get,
                "/users/:id",
                operation:
                    OpenAPIOperation(
                        operationID:
                            "optionalID",
                        validation:
                            ValidationSchema(
                                fields: [
                                    .path(
                                        "id",
                                        required:
                                            false
                                    ),
                                ]
                            )
                    )
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    OpenAPIRegistryError,
                .optionalPathParameter(
                    "id"
                )
            )
        }

        XCTAssertThrowsError(
            try registry.register(
                .get,
                "/users/:id",
                operation:
                    OpenAPIOperation(
                        operationID:
                            "wrongPath",
                        validation:
                            ValidationSchema(
                                fields: [
                                    .path(
                                        "other"
                                    ),
                                ]
                            )
                    )
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    OpenAPIRegistryError,
                .unknownPathParameter(
                    "other"
                )
            )
        }
    }

    func testPathTemplateRequiresSharedValidationField() throws {
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "API",
                        version: "1"
                    )
            )

        XCTAssertThrowsError(
            try registry.register(
                .get,
                "/users/:id",
                operation:
                    OpenAPIOperation(
                        operationID:
                            "missingIDValidation"
                    )
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    OpenAPIRegistryError,
                .missingPathParameterValidation(
                    "id"
                )
            )
        }
    }

    func testJSONBodyUsesSameValidationLimitsInDocument() throws {
        let limits =
            JSONValidationLimits(
                maxBytes: 4096,
                maxDepth: 8
            )
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "API",
                        version: "1"
                    )
            )

        try registry.register(
            .post,
            "/users",
            operation:
                OpenAPIOperation(
                    operationID:
                        "createUser",
                    jsonBody:
                        OpenAPIJSONBody(
                            schema:
                                .object(
                                    properties: [
                                        "name":
                                            .string(),
                                    ],
                                    required: [
                                        "name",
                                    ]
                                ),
                            limits: limits
                        )
                )
        )

        let root =
            try jsonObject(
                registry.jsonData()
            )
        let requestBody =
            try operation(
                root,
                path: "/users",
                method: "post"
            )["requestBody"]
                as? [String: Any]

        XCTAssertEqual(
            requestBody?[
                "x-whitethroated-max-bytes"
            ] as? Int,
            limits.maxBytes
        )
        XCTAssertEqual(
            requestBody?[
                "x-whitethroated-max-depth"
            ] as? Int,
            limits.maxDepth
        )
    }

    func testYAMLAndPreparedServiceAreBuiltAtSetup() throws {
        var registry =
            OpenAPIRegistry(
                info:
                    OpenAPIInfo(
                        title: "API",
                        version: "1"
                    )
            )
        try registry.register(
            .get,
            "/health",
            operation:
                OpenAPIOperation(
                    operationID: "health"
                )
        )

        let yaml =
            try registry.yamlString()

        XCTAssertTrue(
            yaml.contains(
                "\"openapi\": \"3.1.0\""
            )
        )
        XCTAssertTrue(
            yaml.contains(
                "\"/health\":"
            )
        )

        let service =
            try OpenAPIService(
                registry: registry
            )

        XCTAssertEqual(
            service.json.status,
            .ok
        )
        XCTAssertEqual(
            service.yaml.status,
            .ok
        )
        XCTAssertGreaterThan(
            service.json.contentLength,
            0
        )
        XCTAssertGreaterThan(
            service.yaml.contentLength,
            0
        )
    }

    private func jsonObject(
        _ data: Data
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization
                .jsonObject(
                    with: data
                )
                as? [String: Any]
        )
    }

    private func operation(
        _ root: [String: Any],
        path: String,
        method: String
    ) throws -> [String: Any] {
        let paths =
            try XCTUnwrap(
                root["paths"]
                    as? [String: Any]
            )
        let pathValue =
            try XCTUnwrap(
                paths[path]
                    as? [String: Any]
            )

        return try XCTUnwrap(
            pathValue[method]
                as? [String: Any]
        )
    }

    private func parameter(
        named name: String,
        in parameters:
            [[String: Any]]
    ) throws -> [String: Any] {
        try XCTUnwrap(
            parameters.first {
                $0["name"] as? String
                == name
            }
        )
    }
}
