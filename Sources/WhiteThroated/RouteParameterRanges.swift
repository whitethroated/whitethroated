private struct RouteParameterCapture: Sendable {
    let range: Range<Int>
    let requiresDecoding: Bool
}

internal enum RouteParameterRanges: Sendable {
    case none
    case one(RouteParameterCapture)
    case two(
        RouteParameterCapture,
        RouteParameterCapture
    )
    case many([RouteParameterCapture])

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
        capture(at: index).range
    }

    @inline(__always)
    func requiresDecoding(
        at index: Int
    ) -> Bool {
        capture(at: index).requiresDecoding
    }

    mutating func append(
        _ range: Range<Int>,
        requiresDecoding: Bool = true
    ) {
        let capture = RouteParameterCapture(
            range: range,
            requiresDecoding: requiresDecoding
        )

        switch self {
        case .none:
            self = .one(capture)

        case .one(let first):
            self = .two(
                first,
                capture
            )

        case .two(let first, let second):
            self = .many([
                first,
                second,
                capture
            ])

        case .many(var ranges):
            ranges.append(capture)
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

    @inline(__always)
    private func capture(
        at index: Int
    ) -> RouteParameterCapture {
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
}
