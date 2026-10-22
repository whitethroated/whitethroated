import Foundation
import WhiteThroated

public struct OpenAPIService:
    Sendable
{
    public let json:
        PreparedResponse
    public let yaml:
        PreparedResponse

    private let documentTitle:
        String

    public init(
        registry: OpenAPIRegistry
    ) throws {
        let jsonData =
            try registry.jsonData()
        let yamlValue =
            try registry.yamlString()

        self.json =
            PreparedResponse.bytes(
                Array(jsonData),
                contentType:
                    "application/json; charset=utf-8"
            )
        self.yaml =
            PreparedResponse.bytes(
                Array(yamlValue.utf8),
                contentType:
                    "application/yaml; charset=utf-8"
            )
        self.documentTitle =
            registry.info.title
    }

    public func mount(
        on application: Application,
        jsonPath:
            String = "/openapi.json",
        yamlPath:
            String? = "/openapi.yaml",
        uiPath:
            String? = "/docs"
    ) {
        application.get(
            jsonPath,
            response: json
        )

        if let yamlPath {
            application.get(
                yamlPath,
                response: yaml
            )
        }

        if let uiPath {
            application.get(
                uiPath,
                response:
                    PreparedResponse.html(
                        Self.uiHTML(
                            title:
                                documentTitle,
                            jsonPath:
                                jsonPath
                        )
                    )
            )
        }
    }

    internal static func uiHTML(
        title: String,
        jsonPath: String
    ) -> String {
        let pathLiteral =
            javaScriptStringLiteral(
                jsonPath
            )
        let titleLiteral =
            javaScriptStringLiteral(
                title
            )
        let htmlTitle =
            escapeHTML(title)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>\(htmlTitle) API</title>
          <style>
            body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 2rem; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; }
          </style>
        </head>
        <body>
          <h1 id="title"></h1>
          <pre id="document">Loading…</pre>
          <script>
            const title = \(titleLiteral);
            const path = \(pathLiteral);
            document.getElementById("title").textContent = title + " API";
            fetch(path, { credentials: "same-origin" })
              .then(response => {
                if (!response.ok) throw new Error("OpenAPI fetch failed");
                return response.json();
              })
              .then(documentValue => {
                document.getElementById("document").textContent =
                  JSON.stringify(documentValue, null, 2);
              })
              .catch(error => {
                document.getElementById("document").textContent =
                  String(error);
              });
          </script>
        </body>
        </html>
        """
    }

    private static func javaScriptStringLiteral(
        _ value: String
    ) -> String {
        let encoder =
            JSONEncoder()
        encoder.outputFormatting = [
            .withoutEscapingSlashes,
        ]
        let data =
            try! encoder.encode(value)
        let encoded =
            String(
                decoding: data,
                as: UTF8.self
            )

        return encoded
            .replacingOccurrences(
                of: "<",
                with: "\\u003c"
            )
            .replacingOccurrences(
                of: ">",
                with: "\\u003e"
            )
            .replacingOccurrences(
                of: "&",
                with: "\\u0026"
            )
    }

    private static func escapeHTML(
        _ value: String
    ) -> String {
        value
            .replacingOccurrences(
                of: "&",
                with: "&amp;"
            )
            .replacingOccurrences(
                of: "<",
                with: "&lt;"
            )
            .replacingOccurrences(
                of: ">",
                with: "&gt;"
            )
            .replacingOccurrences(
                of: "\"",
                with: "&quot;"
            )
            .replacingOccurrences(
                of: "'",
                with: "&#39;"
            )
    }
}
