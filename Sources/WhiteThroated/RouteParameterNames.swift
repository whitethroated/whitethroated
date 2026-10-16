internal enum RouteParameterNames: Sendable {
    case none
    case one(String)
    case two(String, String)
    case many([String])

    var count: Int {
        switch self {
        case .none:
            return 0
        case .one:
            return 1
        case .two:
            return 2
        case .many(let names):
            return names.count
        }
    }

    var isEmpty: Bool {
        count == 0
    }

    subscript(index: Int) -> String {
        switch self {
        case .none:
            preconditionFailure(
                "Route parameter index out of range"
            )

        case .one(let first):
            precondition(
                index == 0,
                "Route parameter index out of range"
            )
            return first

        case .two(let first, let second):
            switch index {
            case 0:
                return first
            case 1:
                return second
            default:
                preconditionFailure(
                    "Route parameter index out of range"
                )
            }

        case .many(let names):
            return names[index]
        }
    }

    mutating func append(_ name: String) {
        switch self {
        case .none:
            self = .one(name)

        case .one(let first):
            self = .two(
                first,
                name
            )

        case .two(let first, let second):
            self = .many([
                first,
                second,
                name
            ])

        case .many(var names):
            names.append(name)
            self = .many(names)
        }
    }
}
