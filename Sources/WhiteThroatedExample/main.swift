import WhiteThroated

let app = Application()

app.get("/") { _ in
    .text("Hello from WhiteThroated")
}

app.get("/users/:id") { request in
    let id = request.parameter("id") ?? "unknown"
    return .json(#"{"id":"\#(id)"}"#)
}

try app.run(port: 3000)
