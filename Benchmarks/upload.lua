local upload_bytes = tonumber(
    os.getenv("HUDHUD_UPLOAD_BYTES") or "65536"
)

wrk.method = "POST"
wrk.body = string.rep("x", upload_bytes)
wrk.headers["Content-Type"] = "application/octet-stream"
