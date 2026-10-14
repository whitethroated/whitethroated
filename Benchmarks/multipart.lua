local bytes =
  tonumber(os.getenv("HUDHUD_MULTIPART_FILE_BYTES"))
  or 1024

local boundary = "hudhud-benchmark-boundary"
local prefix =
  "--" .. boundary .. "\r\n"
  .. "Content-Disposition: form-data; "
  .. "name=\"file\"; filename=\"payload.bin\"\r\n"
  .. "Content-Type: application/octet-stream\r\n"
  .. "\r\n"
local suffix =
  "\r\n--" .. boundary .. "--\r\n"
local body =
  prefix
  .. string.rep("a", bytes)
  .. suffix

wrk.method = "POST"
wrk.body = body
wrk.headers["content-type"] =
  "multipart/form-data; boundary=" .. boundary
wrk.headers["content-length"] =
  tostring(#body)
