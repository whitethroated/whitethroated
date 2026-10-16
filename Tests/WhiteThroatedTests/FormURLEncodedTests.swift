import XCTest
@testable import WhiteThroated
import NIOCore
import NIOHTTP1

final class FormURLEncodedTests: XCTestCase {
    func testTargetedFormLookup() {
        let request = makeRequest(
            body: "email=san%40example.com&name=San+Engineer"
        )

        XCTAssertEqual(
            request.form("email"),
            "san@example.com"
        )
        XCTAssertEqual(
            request.form("name"),
            "San Engineer"
        )
        XCTAssertNil(
            request.form("missing")
        )
    }

    func testFormParametersMaterializeDictionary() {
        let request = makeRequest(
            body: "a=1&b=hello+world&encoded=%E6%B5%8B%E8%AF%95"
        )

        XCTAssertEqual(
            request.formParameters,
            [
                "a": "1",
                "b": "hello world",
                "encoded": "测试"
            ]
        )
    }

    func testFormDuplicateKeyUsesLastValueWhenMaterialized() {
        let request = makeRequest(
            body: "tag=swift&tag=server"
        )

        XCTAssertEqual(
            request.form("tag"),
            "swift"
        )
        XCTAssertEqual(
            request.formParameters["tag"],
            "server"
        )
    }

    func testEmptyFormBodyReturnsNoValues() {
        let request = makeRequest(body: "")

        XCTAssertNil(
            request.form("anything")
        )
        XCTAssertTrue(
            request.formParameters.isEmpty
        )
    }

    private func makeRequest(
        body value: String
    ) -> Request {
        var buffer = ByteBufferAllocator().buffer(
            capacity: value.utf8.count
        )
        buffer.writeString(value)

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/form"
        )
        head.headers.add(
            name: "content-type",
            value: "application/x-www-form-urlencoded"
        )

        return Request(
            head: head,
            body: buffer
        )
    }
}
