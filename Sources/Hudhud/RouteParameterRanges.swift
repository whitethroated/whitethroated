internal enum RouteParameterRanges: Sendable {
    case none
    case one(Range<Int>)
    case two(Range<Int>, Range<Int>)
    case many([Range<Int>])

    var count: Int {
        switch self {
        case .none:
            return 0
        case .one:
            return 1
        case .two:
            return 2
        case .many(let ranges):
            return ranges.count
        }
    }

    subscript(index: Int) -> Range<Int> {
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

        case .many(let ranges):
            return ranges[index]
        }
    }

    mutating func append(_ range: Range<Int>) {
        switch self {
        case .none:
            self = .one(range)

        case .one(let first):
            self = .two(
                first,
                range
            )

        case .two(let first, let second):
            self = .many([
                first,
                second,
                range
            ])

        case .many(var ranges):
            ranges.append(range)
            self = .many(ranges)
        }
    }

    mutating func removeLast() {
        switch self {
        case .none:
            preconditionFailure(
                "Cannot remove from empty route parameters"
            )

        case .one:
            self = .none

        case .two(let first, _):
            self = .one(first)

        case .many(var ranges):
            ranges.removeLast()

            switch ranges.count {
            case 0:
                self = .none

            case 1:
                self = .one(ranges[0])

            case 2:
                self = .two(
                    ranges[0],
                    ranges[1]
                )

            default:
                self = .many(ranges)
            }
        }
    }
}
