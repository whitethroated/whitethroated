import Testing

@testable import WhiteThroatedHTTP1

@Suite struct WTHTTP1ValidationTests {
    @Test func headerNameAcceptsTokenBytes() {
        #expect(
            WTHTTP1Validation.isValidHeaderName(
                Array("content-length".utf8)
            )
        )
        #expect(
            WTHTTP1Validation.isValidHeaderName(
                Array("X-Custom_123.~!#$%&'*+-^`|".utf8)
            )
        )
    }

    @Test func headerNameRejectsDelimitersAndControls() {
        for byte: UInt8 in [
            0, 9, 10, 13, 32, 34, 40, 41, 44, 47, 58, 59, 60,
            61, 62, 63, 64, 91, 92, 93, 123, 125, 127, 128,
            200, 255,
        ] {
            #expect(
                !WTHTTP1Validation.isValidHeaderName([byte]),
                "byte \(byte) must be rejected in a header name"
            )
        }
    }

    @Test func headerNameEmptyMirrorsNIOVacuousTruth() {
        #expect(
            WTHTTP1Validation.isValidHeaderName(
                [UInt8]()
            )
        )
    }

    @Test func headerValueAcceptsVisibleAndObsText() {
        #expect(
            WTHTTP1Validation.isValidHeaderValue(
                Array("text/plain; charset=utf-8".utf8)
            )
        )
        #expect(
            WTHTTP1Validation.isValidHeaderValue(
                [9, 32, 126, 128, 200, 255]
            )
        )
        #expect(
            WTHTTP1Validation.isValidHeaderValue(
                [UInt8]()
            )
        )
    }

    @Test func headerValueRejectsControlsExceptHTAB() {
        for byte: UInt8 in [
            0, 1, 8, 10, 12, 13, 27, 31, 127,
        ] {
            #expect(
                !WTHTTP1Validation.isValidHeaderValue([byte]),
                "byte \(byte) must be rejected in a header value"
            )
        }

        #expect(
            WTHTTP1Validation.isValidHeaderValue([9])
        )
    }

    @Test func headerValueRejectsResponseSplitting() {
        #expect(
            !WTHTTP1Validation.isValidHeaderValue(
                Array("ok\r\nInjected: yes".utf8)
            )
        )
        #expect(
            !WTHTTP1Validation.isValidHeaderValue(
                Array("ok\nInjected: yes".utf8)
            )
        )
    }

    @Test func reasonPhraseMirrorsNIOCustomStatusRule() {
        #expect(
            WTHTTP1Validation.isValidReasonPhrase(
                Array("OK".utf8)
            )
        )
        #expect(
            WTHTTP1Validation.isValidReasonPhrase(
                [9, 32, 126, 128, 255]
            )
        )

        for byte: UInt8 in [0, 10, 13, 31, 127] {
            #expect(
                !WTHTTP1Validation.isValidReasonPhrase([byte]),
                "byte \(byte) must be rejected in a reason phrase"
            )
        }
    }
}
