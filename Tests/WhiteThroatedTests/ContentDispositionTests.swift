import XCTest
@testable import WhiteThroated

final class ContentDispositionTests: XCTestCase {
    func testASCIIAttachmentFilename() {
        let response = Response
            .text("file")
            .attachment("report.pdf")

        XCTAssertEqual(
            response.headers.first(
                name: "content-disposition"
            ),
            #"attachment; filename="report.pdf""#
        )
    }

    func testAttachmentEscapesQuotedFilename() {
        let response = Response
            .text("file")
            .attachment(#"semi;"quote\\.txt"#)

        XCTAssertEqual(
            response.headers.first(
                name: "content-disposition"
            ),
            #"attachment; filename="semi;\"quote\\\\.txt""#
        )
    }

    func testUnicodeAttachmentUsesExtendedFilename() {
        let response = Response
            .text("file")
            .attachment("laporan 测试.pdf")

        XCTAssertEqual(
            response.headers.first(
                name: "content-disposition"
            ),
            #"attachment; filename="laporan ______.pdf"; filename*=UTF-8''laporan%20%E6%B5%8B%E8%AF%95.pdf"#
        )
    }

    func testAttachmentNeverEmitsRawControlBytes() {
        let response = Response
            .text("file")
            .attachment(
                "safe\r\nx-injected: yes.txt"
            )

        let value = response.headers.first(
            name: "content-disposition"
        ) ?? ""

        XCTAssertFalse(value.contains("\r"))
        XCTAssertFalse(value.contains("\n"))
        XCTAssertTrue(
            value.contains(
                "safe__x-injected: yes.txt"
            )
        )
    }

    func testPreparedAttachmentKeepsCachedHeadInSync() {
        let prepared = PreparedResponse
            .text("file")
            .attachment("report.pdf")

        XCTAssertEqual(
            prepared.response.headers.first(
                name: "content-disposition"
            ),
            #"attachment; filename="report.pdf""#
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-disposition"
            ),
            #"attachment; filename="report.pdf""#
        )
    }
}
