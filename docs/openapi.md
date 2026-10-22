# WhiteThroatedOpenAPI

Status: **experimental**

`WhiteThroatedOpenAPI` builds OpenAPI 3.1 documents at setup time. It depends
on `WhiteThroatedValidation`; Validation does not depend on OpenAPI.

## Shared validation contract

The same `ValidationSchema` value can drive runtime request validation and
OpenAPI parameter documentation:

```swift
import WhiteThroatedOpenAPI
import WhiteThroatedValidation

let userInput = ValidationSchema(
    fields: [
        .path(
            "id",
            rules: [.nonEmpty]
        ),
        .query(
            "include",
            required: false,
            rules: [
                .oneOf(["profile", "roles"])
            ]
        ),
    ]
)

app.get("/users/:id") { request in
    let validation = request.validate(userInput)
    // ...
}

var api = OpenAPIRegistry(
    info: OpenAPIInfo(
        title: "Example API",
        version: "1.0.0"
    )
)

try api.register(
    .get,
    "/users/:id",
    operation: OpenAPIOperation(
        operationID: "getUser",
        validation: userInput
    )
)
```

String validation rules map to OpenAPI string constraints. Custom validation
closures cannot be represented as portable JSON Schema, so the generated schema
marks them with `x-whitethroated-custom-validation: true` rather than pretending
the constraint is machine-readable.

Path parameters must be required and must correspond to `:name` or `*name`
segments in the route. Every path placeholder must have a matching
`ValidationSchema.path` field; registration rejects an undocumented placeholder
rather than emitting an invalid OpenAPI Path Item. WhiteThroated path syntax is
converted to OpenAPI `{name}` syntax during setup.

## JSON bodies

`OpenAPIJSONBody` carries an explicit schema and the same
`JSONValidationLimits` value that the handler can pass to
`decodeValidatedJSON`. Byte and nesting limits are emitted as WhiteThroated
vendor extensions so operational limits are not lost from the contract.

## Collision detection

Registration rejects:

- duplicate method/path pairs;
- duplicate operation IDs;
- optional path parameters;
- path validation fields that do not exist in the route;
- CONNECT and custom HTTP methods that OpenAPI Path Items cannot represent.

These are setup errors, not request-time lookups.

## Serving documents

```swift
let service = try OpenAPIService(
    registry: api
)

service.mount(
    on: app,
    jsonPath: "/openapi.json",
    yamlPath: "/openapi.yaml",
    uiPath: "/docs"
)
```

JSON and YAML are generated once when `OpenAPIService` is created and served as
prepared responses. The optional UI is a small local document viewer with no
CDN or third-party runtime dependency. Set `yamlPath` or `uiPath` to `nil`
to omit those endpoints.

Ordinary application routes do not need OpenAPI metadata. Importing or linking
the module does not discover routes, register middleware, or add request state.
