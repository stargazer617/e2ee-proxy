--
-- e2ee_discovery.lua - Model resolution and nonce management
--
-- Mirrors the Python transport's DiscoveryManager:
--   - resolve_chute_id(model) -> chute_id
--   - get_nonce(chute_id)     -> instance_info, nonce
--
-- Uses ngx.shared.DICT for caching (shared across requests in single worker).
-- Uses lua-resty-http for upstream API calls.
--

local http = require("resty.http")
local cjson = require("cjson.safe")

local _M = {}

-- Cache (module-level, single worker)
local model_map = nil
local model_map_expires = 0
local MODEL_MAP_TTL = 300  -- 5 minutes

-- Nonce cache: { [chute_id] = { instances = [...], expires_at = N } }
local nonce_cache = {}

local API_BASE = "https://api.chutes.ai"
local MODELS_BASE = "https://llm.chutes.ai"

function _M.set_api_base(base)
    API_BASE = base
end

function _M.set_models_base(base)
    MODELS_BASE = base
end

--- Check if a string looks like a UUID
local function is_uuid(s)
    if not s or #s ~= 36 then return false end
    return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

--- Fetch models list from API
local function fetch_model_map(api_key)
    local httpc = http.new()
    httpc:set_timeout(10000)

    local res, err = httpc:request_uri(MODELS_BASE .. "/v1/models", {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
        ssl_verify = true,
    })

    if not res then
        return nil, "model list request failed: " .. (err or "unknown")
    end

    if res.status ~= 200 then
        return nil, "model list returned " .. res.status
    end

    local data = cjson.decode(res.body)
    if not data or not data.data then
        return nil, "invalid model list response"
    end

    local map = {}
    for _, model in ipairs(data.data) do
        if model.id and model.chute_id then
            map[model.id] = {
                chute_id = model.chute_id,
                confidential = model.confidential_compute == true,
            }
        end
    end

    return map
end

local allow_non_confidential = os.getenv("ALLOW_NON_CONFIDENTIAL") == "true"

--- Resolve a model name to a chute_id
-- @param model    Model name or UUID
-- @param api_key  API key for authentication
-- @return chute_id string
local function check_confidential(model, entry)
    if not entry then return nil, "model '" .. model .. "' not found" end
    if not entry.confidential and not allow_non_confidential then
        return nil, "model '" .. model .. "' is not running in confidential compute (TEE). "
            .. "E2EE requires confidential compute to guarantee privacy. "
            .. "Set ALLOW_NON_CONFIDENTIAL=true to override."
    end
    return entry.chute_id
end

function _M.resolve_chute_id(model, api_key)
    if is_uuid(model) then
        return model
    end

    -- Strip the :THINKING suffix before map lookup. v1/models returns
    -- base model IDs only; :THINKING is a proxy-side flag and must not
    -- leak into the lookup key. Other suffixes (e.g. LoRA names) are
    -- left intact so they surface as proper errors upstream rather than
    -- silently resolving to the base chute.
    local base_model = model:match("^(.-):THINKING$") or model

    local now = ngx.now()

    -- Check cache
    if model_map and now < model_map_expires then
        local entry = model_map[base_model]
        if entry then
            return check_confidential(model, entry)
        end
    end

    -- Fetch fresh model map
    local map, err = fetch_model_map(api_key)
    if not map then
        -- If we have a stale cache, try it
        if model_map then
            local entry = model_map[base_model]
            if entry then
                return check_confidential(model, entry)
            end
        end
        return nil, "failed to resolve model '" .. model .. "': " .. (err or "unknown")
    end

    model_map = map
    model_map_expires = now + MODEL_MAP_TTL

    local entry = map[base_model]
    return check_confidential(model, entry)
end

--- Fetch instances and nonces for a chute
local function fetch_instances(chute_id, api_key)
    local httpc = http.new()
    httpc:set_timeout(30000)

    local url = API_BASE .. "/e2e/instances/" .. chute_id
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
            ["Cache-Control"] = "no-cache, no-store",
        },
        ssl_verify = true,
    })

    if not res then
        return nil, "instance discovery failed: " .. (err or "unknown")
    end

    if res.status ~= 200 then
        return nil, "instance discovery returned " .. res.status .. ": " .. (res.body or "")
    end

    local data = cjson.decode(res.body)
    if not data or not data.instances then
        return nil, "invalid instance discovery response: " .. (res.body or ""):sub(1, 200)
    end

    local nonce_ttl = data.nonce_expires_in or 55
    local expires_at = ngx.now() + nonce_ttl

    local total_nonces = 0
    for _, inst in ipairs(data.instances) do
        if inst.nonces then
            total_nonces = total_nonces + #inst.nonces
            ngx.log(ngx.INFO, "  instance=", inst.instance_id,
                    " nonces=", #inst.nonces,
                    " first_nonce_prefix=", inst.nonces[1] and inst.nonces[1]:sub(1, 8) or "nil",
                    " pubkey_len=", inst.e2e_pubkey and #inst.e2e_pubkey or 0)
        end
    end
    ngx.log(ngx.INFO, "fetched ", #data.instances, " instances with ",
            total_nonces, " nonces (TTL=", nonce_ttl, "s) for chute ", chute_id)

    return {
        instances = data.instances,
        expires_at = expires_at,
    }
end

--- Take one nonce from the cache for a chute_id
local function take_nonce(chute_id)
    local cached = nonce_cache[chute_id]
    if not cached then return nil end
    if ngx.now() >= cached.expires_at then
        nonce_cache[chute_id] = nil
        return nil
    end

    for _, inst in ipairs(cached.instances) do
        if inst.nonces and #inst.nonces > 0 then
            local nonce = table.remove(inst.nonces, 1)
            ngx.log(ngx.INFO, "take_nonce: instance=", inst.instance_id,
                    " nonce_prefix=", nonce:sub(1, 12),
                    " remaining=", #inst.nonces)
            return {
                instance_id = inst.instance_id,
                e2e_pubkey = inst.e2e_pubkey,
            }, nonce
        end
    end

    -- All nonces consumed
    nonce_cache[chute_id] = nil
    return nil
end

--- Invalidate cached nonces for a chute (force refresh on next get_nonce)
function _M.invalidate_nonces(chute_id)
    nonce_cache[chute_id] = nil
end

--- Get an instance and nonce for a chute
-- @param chute_id  Chute UUID
-- @param api_key   API key
-- @return instance_info table {instance_id, e2e_pubkey}, nonce string
function _M.get_nonce(chute_id, api_key)
    -- Try cached first
    local inst, nonce = take_nonce(chute_id)
    if inst then
        return inst, nonce
    end

    -- Fetch fresh
    local cached, err = fetch_instances(chute_id, api_key)
    if not cached then
        return nil, nil, err
    end

    nonce_cache[chute_id] = cached

    inst, nonce = take_nonce(chute_id)
    if not inst then
        return nil, nil, "no nonces available for chute " .. chute_id
    end

    return inst, nonce
end

return _M
