import CoreFoundation
import Foundation

internal enum OpenAPIYAML {
    static func encode(
        _ jsonData: Data
    ) throws -> String {
        let object =
            try JSONSerialization
                .jsonObject(
                    with: jsonData
                )

        return render(
            object,
            indent: 0
        )
        + "\n"
    }

    private static func render(
        _ value: Any,
        indent: Int
    ) -> String {
        if let dictionary =
            value as? [String: Any]
        {
            return renderDictionary(
                dictionary,
                indent: indent
            )
        }

        if let array =
            value as? [Any]
        {
            return renderArray(
                array,
                indent: indent
            )
        }

        return scalar(value)
    }

    private static func renderDictionary(
        _ dictionary:
            [String: Any],
        indent: Int
    ) -> String {
        let prefix =
            String(
                repeating: " ",
                count: indent
            )

        // An empty object must render as a flow mapping;
        // the sorted-key rendering would otherwise produce
        // an empty string and corrupt the document.
        if dictionary.isEmpty {
            return prefix + "{}"
        }

        return dictionary.keys
            .sorted()
            .map {
                key in

                let value =
                    dictionary[key]!

                if isCollection(value) {
                    return
                        prefix
                        + quote(key)
                        + ":\n"
                        + render(
                            value,
                            indent:
                                indent + 2
                        )
                }

                return
                    prefix
                    + quote(key)
                    + ": "
                    + scalar(value)
            }
            .joined(
                separator: "\n"
            )
    }

    private static func renderArray(
        _ array: [Any],
        indent: Int
    ) -> String {
        let prefix =
            String(
                repeating: " ",
                count: indent
            )

        if array.isEmpty {
            return prefix + "[]"
        }

        return array.map {
            value in

            if isCollection(value) {
                return
                    prefix
                    + "-\n"
                    + render(
                        value,
                        indent:
                            indent + 2
                    )
            }

            return
                prefix
                + "- "
                + scalar(value)
        }
        .joined(separator: "\n")
    }

    private static func isCollection(
        _ value: Any
    ) -> Bool {
        value is [String: Any]
        || value is [Any]
    }

    private static func scalar(
        _ value: Any
    ) -> String {
        if value is NSNull {
            return "null"
        }

        if let value =
            value as? String
        {
            return quote(value)
        }

        if let value =
            value as? NSNumber
        {
            // JSONSerialization bridges both numbers and booleans to
            // NSNumber. A numeric 0/1 also casts to Bool, so preserve
            // the actual JSON type rather than using `as? Bool`.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        }

        return quote(
            String(
                describing: value
            )
        )
    }

    private static func quote(
        _ value: String
    ) -> String {
        let encoder =
            JSONEncoder()
        encoder.outputFormatting = [
            .withoutEscapingSlashes,
        ]
        let data =
            try! encoder.encode(value)

        return String(
            data: data,
            encoding: .utf8
        )!
    }
}
