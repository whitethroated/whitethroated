# WhiteThroatedValidation

Status: **experimental**

`WhiteThroatedValidation` is an opt-in request validation module. Importing the
product does not register middleware or change the WhiteThroated core/runtime
request path.

## Field validation

Build immutable schemas during application setup and evaluate them only inside
handlers that need validation:

```swift
import WhiteThroated
import WhiteThroatedValidation

let createUser = ValidationSchema(
    fields: [
        .path(
            "account",
            rules: [.nonEmpty]
        ),
        .query(
            "mode",
            required: false,
            rules: [
                .oneOf(["safe", "fast"])
            ]
        ),
        .header("x-request-id"),
    ]
)

app.post("/accounts/:account/users") { request in
    guard
        let values = try? request
            .validate(createUser)
            .get()
    else {
        return .text(
            "Invalid request",
            status: .badRequest
        )
    }

    let account =
        values[.path, "account"] ?? ""

    return .text(account)
}
```

A schema reports all field issues found in one validation pass. Each
`ValidationIssue` identifies its location, optional field name, stable issue
code, and human-readable message.

Supported string locations in this first slice are path parameters, query
parameters, headers, and cookies. Optional fields are not evaluated when absent.

## JSON body validation

JSON decoding stays explicit and lazy. A route that never calls
`decodeValidatedJSON` does not scan or decode the body.

```swift
struct CreateUser: Decodable {
    let name: String
}

let payload: CreateUser =
    try request.decodeValidatedJSON(
        limits: JSONValidationLimits(
            maxBytes: 64 * 1024,
            maxDepth: 16
        )
    )
```

The byte limit is checked before creating the `Data` used by `JSONDecoder`.
The depth guard scans the existing `ByteBuffer` without allocating a parsed
JSON tree and ignores bracket characters that occur inside JSON strings.
Malformed JSON and type mismatches are returned as a structured body validation
failure.

The server-level `maxRequestBodyBytes` remains the authoritative transport
limit. `JSONValidationLimits.maxBytes` is a narrower application-level limit,
not a replacement for transport framing limits.

## Cost model

- Product not linked: no Validation code is present in the application's module
  graph.
- Product linked but route does not call it: no middleware, registry lookup,
  `Task`, future, or per-request Validation allocation is introduced.
- Schema validation: work is proportional to configured fields and rules.
- JSON body validation: one bounded depth scan occurs before normal Codable
  decoding.

No performance claim is made yet. Feature-specific release benchmarks must
measure disabled, linked-but-unused, and active conditions before this module can
move beyond experimental status.

## Current boundaries

This experimental slice intentionally does not provide:

- automatic global validation middleware;
- reflection-based model validation;
- regex compilation hidden in request-time rules;
- OpenAPI generation;
- streaming JSON schema validation;
- automatic conversion of validation failures into a framework-wide error body.

Those decisions remain separate so Validation does not force overhead or API
semantics onto routes that do not use it.
