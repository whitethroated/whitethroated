enum RouterByteEquality {
    @inline(__always)
    static func equals<C: Collection, D: Collection>(
        _ lhs: C,
        _ rhs: D
    ) -> Bool
    where C.Element == UInt8, D.Element == UInt8 {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex

        while
            leftIndex != lhs.endIndex,
            rightIndex != rhs.endIndex
        {
            guard lhs[leftIndex] == rhs[rightIndex] else {
                return false
            }

            lhs.formIndex(after: &leftIndex)
            rhs.formIndex(after: &rightIndex)
        }

        return leftIndex == lhs.endIndex
            && rightIndex == rhs.endIndex
    }
}
