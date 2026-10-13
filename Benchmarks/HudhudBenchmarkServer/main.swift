import Foundation
import Hudhud

let environment = ProcessInfo.processInfo.environment
let host = environment["HUDHUD_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["HUDHUD_PORT"] ?? "3000"
) ?? 3000

let app = Application()

app.get(
    "/prepared",
    response: .text("Hello, World!")
)

app.get("/plaintext") { _ in
    .text("Hello, World!")
}

app.get("/json") { _ in
    .json(#"{"message":"Hello, World!"}"#)
}

app.get("/users/:id") { request in
    .text(request.parameter("id") ?? "")
}

app.get("/users/:id/posts/:post") { request in
    let id = request.parameter("id") ?? ""
    let post = request.parameter("post") ?? ""

    return .text("\(id):\(post)")
}

try app.run(host: host, port: port)
