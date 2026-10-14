local bytes = tonumber(os.getenv("HUDHUD_UPLOAD_BYTES")) or 1024
local body = string.rep("a", bytes)

wrk.method = "POST"
wrk.body = body
wrk.headers["content-type"] = "application/octet-stream"
wrk.headers["content-length"] = tostring(bytes)
