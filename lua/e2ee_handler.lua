--
-- e2ee_handler.lua - Main nginx request handler
--
-- Transparently intercepts OpenAI-compatible requests, encrypts them
-- using the E2EE protocol, sends to api.chutes.ai, and decrypts responses.
--
-- Handles both streaming (SSE) and non-streaming responses.
-- Exposes reusable core functions for other format handlers.
--

local crypto = require("e2ee_crypto")
local discovery = require("e2ee_discovery")
local cjson = require("cjson.safe")
local http = require("resty.http")

local API_BASE = "https://api.chutes.ai"

local _M = {}

--- Extract API key from Authorization header or x-api-key
function _M.get_api_key()
    local headers = ngx.req.get_headers()

    -- Check x-api-key first (Anthropic SDK uses this)
    local key = headers["x-api-key"]
    if key then
        return key
    end

    -- Fall back to Authorization header (OpenAI SDK)
    local auth = headers["Authorization"]
    if not auth then
        return nil, "missing Authorization header"
    end
    -- Support both "Bearer <key>" and raw "<key>" formats
    key = auth:match("^Bearer%s+(.+)$")
    if not key then
        key = auth
    end
    return key
end

--- Send error response
function _M.send_error(status, message)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        error = {
            message = message,
            type = "proxy_error",
        }
    }))
    return ngx.exit(status)
end

--- Process a single SSE line
local function process_sse_line(line, stream_key, response_sk)
    line = line:gsub("\r$", "")

    if not line:match("^data: ") then
        return nil, nil, nil  -- skip non-data lines
    end

    local raw = line:sub(7):match("^%s*(.-)%s*$")

    if raw == "[DONE]" then
        return "done", nil, nil
    end

    if not raw or raw == "" then
        return nil, nil, nil
    end

    local event = cjson.decode(raw)
    if not event then
        return nil, nil, nil
    end

    if event.e2e_init then
        local key, err = crypto.decrypt_stream_init(response_sk, event.e2e_init)
        if not key then
            return "error", nil, "stream init failed: " .. (err or "unknown")
        end
        return "init", key, nil

    elseif event.e2e then
        if not stream_key then
            return "error", nil, "received e2e chunk before e2e_init"
        end
        local decrypted, err = crypto.decrypt_stream_chunk(event.e2e, stream_key)
        if not decrypted then
            return "error", nil, "chunk decryption failed: " .. (err or "unknown")
        end
        return "chunk", decrypted, nil

    elseif event.usage then
        return "passthrough", line, nil

    elseif event.e2e_error then
        local error_data = cjson.encode({error = event.e2e_error})
        return "chunk", "data: " .. error_data, nil
    end

    return nil, nil, nil
end

--- E2EE round-trip: encrypt request, send, decrypt response
-- For non-streaming: returns (decrypted_json_string, nil) or (nil, {status=N, message=S})
-- For streaming: calls on_chunk(line) for each decrypted SSE data line, on_chunk(nil) at end
function _M.e2ee_round_trip(api_key, model, body_json, is_streaming, e2e_path, on_chunk)
    local err

    -- Resolve model -> chute_id
    local chute_id
    chute_id, err = discovery.resolve_chute_id(model, api_key)
    if not chute_id then
        return nil, {status = 404, message = err}
    end

    -- Try up to 2 times (retry on nonce errors)
    local res, httpc, response_sk
    for attempt = 1, 2 do
        -- Get nonce (force refresh on retry)
        local instance, nonce
        if attempt > 1 then
            discovery.invalidate_nonces(chute_id)
        end
        instance, nonce, err = discovery.get_nonce(chute_id, api_key)
        if not instance then
            return nil, {status = 503, message = err}
        end

        ngx.log(ngx.INFO, "attempt ", attempt, ": instance=", instance.instance_id,
                " nonce=", nonce, " chute=", chute_id,
                " auth_len=", #api_key, " auth_prefix=", api_key:sub(1, 8))

        -- Build encrypted request
        local blob
        blob, response_sk, err = crypto.build_e2ee_request(instance.e2e_pubkey, body_json)
        if not blob then
            return nil, {status = 500, message = "encryption failed: " .. (err or "unknown")}
        end

        -- Connect to upstream
        httpc = http.new()
        httpc:set_timeouts(5000, 30000, 300000)

        local url_parts = httpc:parse_uri(API_BASE .. "/e2e/invoke")
        local scheme, host, port, path = url_parts[1], url_parts[2], url_parts[3], url_parts[4]

        local ok
        ok, err = httpc:connect(host, port)
        if not ok then
            return nil, {status = 502, message = "upstream connect failed: " .. (err or "unknown")}
        end

        if scheme == "https" then
            local session
            session, err = httpc:ssl_handshake(nil, host, true)
            if not session then
                return nil, {status = 502, message = "upstream SSL failed: " .. (err or "unknown")}
            end
        end

        -- Send request
        res, err = httpc:request({
            method = "POST",
            path = path,
            body = blob,
            headers = {
                ["Host"] = host,
                ["Authorization"] = "Bearer " .. api_key,
                ["X-Chute-Id"] = chute_id,
                ["X-Instance-Id"] = instance.instance_id,
                ["X-E2E-Nonce"] = nonce,
                ["X-E2E-Stream"] = tostring(is_streaming),
                ["X-E2E-Path"] = e2e_path,
                ["Content-Type"] = "application/octet-stream",
            },
        })

        if not res then
            return nil, {status = 502, message = "upstream request failed: " .. (err or "unknown")}
        end

        -- Retry on 403 nonce errors
        if res.status == 403 and attempt < 2 then
            local err_body = res:read_body()
            ngx.log(ngx.WARN, "403 on attempt ", attempt,
                    ": body=", err_body or "(nil)",
                    " instance=", instance.instance_id,
                    " nonce_prefix=", nonce:sub(1, 12),
                    " nonce_len=", #nonce,
                    " chute=", chute_id)
            if err_body and err_body:find("nonce") then
                ngx.log(ngx.WARN, "nonce rejected, retrying with fresh nonce")
                httpc:close()
                -- continue to next attempt
            else
                -- Non-nonce 403, passthrough
                local body_text = err_body or ""
                httpc:set_keepalive()
                return nil, {status = 403, message = body_text, raw = true}
            end
        else
            break
        end
    end

    -- Non-200: passthrough error
    if res.status ~= 200 then
        local err_body = res:read_body() or ""
        httpc:set_keepalive()
        return nil, {status = res.status, message = err_body, raw = true,
                     content_type = res.headers["Content-Type"]}
    end

    if not is_streaming then
        -- Non-streaming: read full body, decrypt, return
        local response_blob = res:read_body()
        if not response_blob or #response_blob == 0 then
            httpc:set_keepalive()
            return nil, {status = 502, message = "empty response from upstream"}
        end

        local decrypted
        decrypted, err = crypto.decrypt_response(response_blob, response_sk)
        if not decrypted then
            httpc:set_keepalive()
            return nil, {status = 502, message = "failed to decrypt response: " .. (err or "unknown")}
        end

        httpc:set_keepalive()
        return decrypted, nil
    else
        -- Streaming: parse SSE, decrypt chunks, call on_chunk for each
        local reader = res.body_reader
        if not reader then
            httpc:set_keepalive()
            return nil, {status = 502, message = "no body reader"}
        end

        local buffer = ""
        local stream_key = nil
        local done_sent = false

        while true do
            local chunk
            chunk, err = reader(8192)
            if err then
                ngx.log(ngx.ERR, "stream read error: ", err)
                break
            end
            if not chunk then break end

            buffer = buffer .. chunk

            while true do
                local pos = buffer:find("\n")
                if not pos then break end

                local line = buffer:sub(1, pos - 1)
                buffer = buffer:sub(pos + 1)

                if line ~= "" then
                    local event_type, data, event_err = process_sse_line(
                        line, stream_key, response_sk
                    )

                    if event_type == "init" then
                        stream_key = data

                    elseif event_type == "chunk" then
                        on_chunk(data)

                    elseif event_type == "passthrough" then
                        on_chunk(data)

                    elseif event_type == "done" then
                        on_chunk(nil)
                        done_sent = true

                    elseif event_type == "error" then
                        ngx.log(ngx.ERR, "stream error: ", event_err)
                        on_chunk("data: " .. cjson.encode({
                            error = {message = event_err}
                        }))
                        on_chunk(nil)
                        done_sent = true
                    end
                end
            end
        end

        -- Process remaining buffer
        if buffer ~= "" and not done_sent then
            local event_type, data, _ = process_sse_line(
                buffer, stream_key, response_sk
            )
            if event_type == "chunk" or event_type == "passthrough" then
                on_chunk(data)
            elseif event_type == "done" then
                on_chunk(nil)
                done_sent = true
            end
        end

        -- Always signal end of stream
        if not done_sent then
            on_chunk(nil)
        end

        httpc:set_keepalive()
        return true, nil
    end
end

--- Main handler for /v1/chat/completions (and other /v1/* paths)
function _M.handle()
    -- Read request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "rb")
            if f then
                body = f:read("*a")
                f:close()
            end
        end
    end

    if not body then
        return _M.send_error(400, "missing request body")
    end

    local payload = cjson.decode(body)
    if not payload then
        return _M.send_error(400, "invalid JSON body")
    end

    local model = payload.model
    if not model then
        return _M.send_error(400, "missing 'model' field")
    end

    local is_streaming = (payload.stream == true)
    local original_path = ngx.var.uri

    local api_key, err = _M.get_api_key()
    if not api_key then
        return _M.send_error(401, err)
    end

    if not is_streaming then
        local decrypted, round_err = _M.e2ee_round_trip(api_key, model, body, false, original_path)
        if not decrypted then
            if round_err.raw then
                ngx.status = round_err.status
                ngx.header.content_type = round_err.content_type or "application/json"
                ngx.print(round_err.message)
                return
            end
            return _M.send_error(round_err.status, round_err.message)
        end
        ngx.header.content_type = "application/json"
        ngx.print(decrypted)
    else
        -- Set up streaming headers
        ngx.header.content_type = "text/event-stream"
        ngx.header.cache_control = "no-cache"
        ngx.header["X-Accel-Buffering"] = "no"

        local _, round_err = _M.e2ee_round_trip(api_key, model, body, true, original_path,
            function(line)
                if line == nil then
                    ngx.print("data: [DONE]\n\n")
                    ngx.flush(true)
                else
                    local trimmed = line:gsub("%s+$", "")
                    if trimmed ~= "" then
                        ngx.print(trimmed .. "\n\n")
                        ngx.flush(true)
                    end
                end
            end)

        if round_err then
            if round_err.raw then
                ngx.status = round_err.status
                ngx.header.content_type = round_err.content_type or "application/json"
                ngx.print(round_err.message)
            else
                _M.send_error(round_err.status, round_err.message)
            end
        end
    end
end

return _M
