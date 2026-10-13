use std::env;

use actix_web::{
    App,
    HttpResponse,
    HttpServer,
    web,
};

const BODY: &str = "Hello, World!";

async fn plaintext() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(BODY)
}

async fn dynamic(path: web::Path<String>) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(path.into_inner())
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let host = env::var("HUDHUD_HOST")
        .unwrap_or_else(|_| "127.0.0.1".to_owned());

    let port = env::var("HUDHUD_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(3000);

    let workers = env::var("HUDHUD_WORKERS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(4);

    HttpServer::new(|| {
        App::new()
            .route(
                "/plaintext",
                web::get().to(plaintext),
            )
            .route(
                "/users/{id}",
                web::get().to(dynamic),
            )
    })
    .workers(workers)
    .bind((host, port))?
    .run()
    .await
}
