--
-- Unit tests for e2ee_handler.handle_thinking
--
-- Runs the :THINKING suffix / X-Enable-Thinking header logic in isolation
-- by stubbing the openresty globals (ngx, cjson.safe, resty.http) and the
-- sibling lua modules that e2ee_handler requires but doesn't exercise here.
--
-- Usage:
--   luajit tests/test_thinking.lua
--
-- Exits non-zero on any assertion failure.
--

-- Make lua/ importable regardless of cwd.
local script_path = arg and arg[0] or ""
local script_dir = script_path:match("(.*/)") or "./"
package.path = script_dir .. "../lua/?.lua;" .. package.path

-- Stub ngx. The only surface handle_thinking touches is ngx.req.get_headers().
local stub_headers = {}
_G.ngx = {
    req = {
        get_headers = function() return stub_headers end,
    },
    log = function() end,
    INFO = 0, WARN = 0, ERR = 0,
    now = function() return 0 end,
}

-- Stub modules that e2ee_handler requires but handle_thinking doesn't use.
package.loaded["cjson.safe"] = { encode = function(x) return x end, decode = function(x) return x end }
package.loaded["resty.http"] = { new = function() return {} end }
package.loaded["e2ee_crypto"] = {}
package.loaded["e2ee_discovery"] = {}

local e2ee = require("e2ee_handler")

local failures = 0
local total = 0

local function set_header(name, value)
    stub_headers = {}
    if value ~= nil then stub_headers[name] = value end
end

local function assert_eq(label, actual, expected)
    total = total + 1
    local ok
    if type(expected) == "table" and type(actual) == "table" then
        ok = true
        for k, v in pairs(expected) do
            if actual[k] ~= v then ok = false; break end
        end
        if ok then
            for k, v in pairs(actual) do
                if expected[k] ~= v then ok = false; break end
            end
        end
    else
        ok = (actual == expected)
    end
    if not ok then
        failures = failures + 1
        io.stderr:write(string.format(
            "FAIL %s\n  expected: %s\n  actual:   %s\n",
            label, tostring(expected), tostring(actual)
        ))
    else
        io.stdout:write("ok   " .. label .. "\n")
    end
end

-- 1. Missing model → returns request, nil; no mutation.
set_header()
do
    local req = { stream = true }
    local out, model = e2ee.handle_thinking(req)
    assert_eq("nil model returns nil", model, nil)
    assert_eq("nil model leaves request untouched", out.chat_template_kwargs, nil)
end

-- 2. Plain model, no suffix, no header, no kwargs → unchanged.
set_header()
do
    local req = { model = "deepseek-ai/DeepSeek-V3.1-TEE" }
    local out, model = e2ee.handle_thinking(req)
    assert_eq("plain model name preserved", model, "deepseek-ai/DeepSeek-V3.1-TEE")
    assert_eq("plain model payload.model preserved", out.model, "deepseek-ai/DeepSeek-V3.1-TEE")
    assert_eq("plain model leaves kwargs absent", out.chat_template_kwargs, nil)
end

-- 3. :THINKING suffix → strip, set both keys.
set_header()
do
    local req = { model = "zai-org/GLM-5.1-TEE:THINKING" }
    local out, model = e2ee.handle_thinking(req)
    assert_eq(":THINKING strips suffix (return)", model, "zai-org/GLM-5.1-TEE")
    assert_eq(":THINKING strips suffix (payload)", out.model, "zai-org/GLM-5.1-TEE")
    assert_eq(":THINKING sets thinking=true", out.chat_template_kwargs.thinking, true)
    assert_eq(":THINKING sets enable_thinking=true", out.chat_template_kwargs.enable_thinking, true)
end

-- 4. X-Enable-Thinking: true → sets both keys, no suffix.
set_header("X-Enable-Thinking", "true")
do
    local req = { model = "zai-org/GLM-5.1-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("header=true sets thinking", out.chat_template_kwargs.thinking, true)
    assert_eq("header=true sets enable_thinking", out.chat_template_kwargs.enable_thinking, true)
    assert_eq("header=true keeps model intact", out.model, "zai-org/GLM-5.1-TEE")
end

-- 5. X-Enable-Thinking: TRUE (uppercase) → case-insensitive.
set_header("X-Enable-Thinking", "TRUE")
do
    local req = { model = "zai-org/GLM-5.1-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("header TRUE case-insensitive", out.chat_template_kwargs.thinking, true)
end

-- 6. X-Enable-Thinking: false → does not set kwargs.
set_header("X-Enable-Thinking", "false")
do
    local req = { model = "deepseek-ai/DeepSeek-V3.1-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("header=false leaves kwargs absent", out.chat_template_kwargs, nil)
end

-- 7. Only `thinking` key → `enable_thinking` propagated.
set_header()
do
    local req = {
        model = "deepseek-ai/DeepSeek-V3.1-TEE",
        chat_template_kwargs = { thinking = true },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("thinking=true propagates to enable_thinking", out.chat_template_kwargs.enable_thinking, true)
end

-- 8. Only `enable_thinking` key → `thinking` propagated.
set_header()
do
    local req = {
        model = "deepseek-ai/DeepSeek-V3.1-TEE",
        chat_template_kwargs = { enable_thinking = false },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("enable_thinking=false propagates to thinking", out.chat_template_kwargs.thinking, false)
end

-- 9. Per-model prefix default-on (GLM-4.7) when kwargs present but no thinking key.
set_header()
do
    local req = {
        model = "zai-org/GLM-4.7",
        chat_template_kwargs = { some_other = "x" },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("GLM-4.7 prefix defaults thinking=true", out.chat_template_kwargs.thinking, true)
    assert_eq("GLM-4.7 prefix defaults enable_thinking=true", out.chat_template_kwargs.enable_thinking, true)
    assert_eq("GLM-4.7 prefix preserves other keys", out.chat_template_kwargs.some_other, "x")
end

-- 10. Per-model exact default-on (GLM-4.7-TEE) when kwargs absent.
set_header()
do
    local req = { model = "zai-org/GLM-4.7-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("GLM-4.7-TEE exact defaults thinking=true", out.chat_template_kwargs.thinking, true)
    assert_eq("GLM-4.7-TEE exact defaults enable_thinking=true", out.chat_template_kwargs.enable_thinking, true)
end

-- 11. Per-model exact default-on for DeepSeek-V3.2-Speciale-TEE and Kimi-K2.5-TEE.
set_header()
do
    local req = { model = "deepseek-ai/DeepSeek-V3.2-Speciale-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("DeepSeek-V3.2-Speciale-TEE exact thinking=true", out.chat_template_kwargs.thinking, true)
end
do
    local req = { model = "moonshotai/Kimi-K2.5-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("Kimi-K2.5-TEE exact thinking=true", out.chat_template_kwargs.thinking, true)
end

-- 12. MiMo-V2-Flash prefix default-off when kwargs present.
set_header()
do
    local req = {
        model = "XiaomiMiMo/MiMo-V2-Flash-Pro",
        chat_template_kwargs = { some_other = "x" },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("MiMo-V2-Flash prefix defaults thinking=false", out.chat_template_kwargs.thinking, false)
    assert_eq("MiMo-V2-Flash prefix defaults enable_thinking=false", out.chat_template_kwargs.enable_thinking, false)
end

-- 13. MiMo-V2-Flash-TEE exact default-off when kwargs absent.
set_header()
do
    local req = { model = "XiaomiMiMo/MiMo-V2-Flash-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("MiMo-V2-Flash-TEE exact thinking=false", out.chat_template_kwargs.thinking, false)
    assert_eq("MiMo-V2-Flash-TEE exact enable_thinking=false", out.chat_template_kwargs.enable_thinking, false)
end

-- 14. :THINKING on MiMo → user override wins over default-off.
set_header()
do
    local req = { model = "XiaomiMiMo/MiMo-V2-Flash-TEE:THINKING" }
    local out, model = e2ee.handle_thinking(req)
    assert_eq(":THINKING on MiMo strips suffix", model, "XiaomiMiMo/MiMo-V2-Flash-TEE")
    assert_eq(":THINKING on MiMo sets thinking=true", out.chat_template_kwargs.thinking, true)
end

-- 15. Non-reasoning model + no suffix + no header → no kwargs injected.
set_header()
do
    local req = { model = "deepseek-ai/DeepSeek-V3.1-TEE" }
    local out = e2ee.handle_thinking(req)
    assert_eq("non-reasoning model leaves kwargs absent", out.chat_template_kwargs, nil)
end

-- 16. :THINKING preserves unrelated kwargs.
set_header()
do
    local req = {
        model = "zai-org/GLM-5.1-TEE:THINKING",
        chat_template_kwargs = { tools_in_user_message = false },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq(":THINKING preserves unrelated kwargs",
        out.chat_template_kwargs.tools_in_user_message, false)
    assert_eq(":THINKING still sets thinking=true",
        out.chat_template_kwargs.thinking, true)
end

-- 17. :THINKING appears mid-string (not suffix) → not stripped.
set_header()
do
    local req = { model = "some:THINKING:other" }
    local out, model = e2ee.handle_thinking(req)
    assert_eq("non-suffix :THINKING not stripped", model, "some:THINKING:other")
    assert_eq("non-suffix :THINKING leaves kwargs absent", out.chat_template_kwargs, nil)
end

-- 18. Explicit thinking=false overrides per-model default-on.
set_header()
do
    local req = {
        model = "zai-org/GLM-4.7",
        chat_template_kwargs = { thinking = false },
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("explicit thinking=false overrides GLM-4.7 default", out.chat_template_kwargs.thinking, false)
    assert_eq("explicit thinking=false propagates enable_thinking=false", out.chat_template_kwargs.enable_thinking, false)
end

-- 19. DeepSeek-V3.2-Speciale prefix (bare, no TEE) with kwargs present.
set_header()
do
    local req = {
        model = "deepseek-ai/DeepSeek-V3.2-Speciale",
        chat_template_kwargs = {},
    }
    local out = e2ee.handle_thinking(req)
    assert_eq("DeepSeek-V3.2-Speciale prefix default thinking=true", out.chat_template_kwargs.thinking, true)
end

io.stdout:write(string.format("\n%d/%d passed\n", total - failures, total))
os.exit(failures == 0 and 0 or 1)
