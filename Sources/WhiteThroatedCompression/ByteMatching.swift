/// Byte-oriented matching helpers shared by the negotiation and
/// content-type policies. All comparisons are ASCII case-insensitive
/// and allocate nothing.
@inline(__always)
internal func asciiFolded(
    _ byte: UInt8
) -> UInt8 {
    byte >= 65 && byte <= 90
        ? byte + 32
        : byte
}

@inline(__always)
internal func isOptionalWhitespace(
    _ byte: UInt8
) -> Bool {
    byte == 32 || byte == 9
}

internal func asciiEquals<Left: Collection, Right: Collection>(
    _ left: Left,
    _ right: Right
) -> Bool where Left.Element == UInt8,
    Right.Element == UInt8
{
    guard left.count == right.count else {
        return false
    }

    var leftIndex = left.startIndex
    var rightIndex = right.startIndex

    while leftIndex != left.endIndex {
        guard
            asciiFolded(left[leftIndex])
                == asciiFolded(right[rightIndex])
        else {
            return false
        }

        left.formIndex(after: &leftIndex)
        right.formIndex(after: &rightIndex)
    }

    return true
}
