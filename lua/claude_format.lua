--
-- claude_format.lua - Claude Messages API <-> OpenAI Chat Completions translation
--

local cjson = require("cjson.safe")

local _M = {}

-- OpenResty cjson encodes empty tables as {} by default.
-- We need content/annotations arrays to be [].
-- Use cjson.encode with a wrapper that patches the JSON string.
local cjson_encode = cjson.encode

-- Encode and patch known empty-object fields that should be arrays
local function encode_with_empty_arrays(obj)
    local json = cjson_encode(obj)
    if not json then return nil end
    -- Patch "content":{} -> "content":[]
    json = json:gsub('"content":{}', '"content":[]')
    -- Patch "annotations":{} -> "annotations":[]
    json = json:gsub('"annotations":{}', '"annotations":[]')
    return json
end
_M.encode = encode_with_empty_arrays

--- Convert Claude Messages API request to OpenAI Chat Completions request
function _M.request_to_openai(claude_body)
    local messages = {}

    -- System prompt
    if claude_body.system then
        local sys_text
        if type(claude_body.system) == "string" then
            sys_text = claude_body.system
        elseif type(claude_body.system) == "table" then
            -- Array of content blocks - extract text blocks
            local parts = {}
            for _, block in ipairs(claude_body.system) do
                if type(block) == "table" and block.type == "text" and block.text then
                    parts[#parts + 1] = block.text
                end
            end
            sys_text = table.concat(parts, "\n")
        end
        if sys_text and sys_text ~= "" then
            messages[#messages + 1] = {role = "system", content = sys_text}
        end
    end

    -- Convert messages
    if claude_body.messages then
        for _, msg in ipairs(claude_body.messages) do
            if type(msg.content) == "string" then
                messages[#messages + 1] = {role = msg.role, content = msg.content}
            elseif type(msg.content) == "table" then
                if msg.role == "user" then
                    _M._convert_user_message(msg, messages)
                elseif msg.role == "assistant" then
                    _M._convert_assistant_message(msg, messages)
                end
            end
        end
    end

    -- Build OpenAI request
    local oai = {
        model = claude_body.model,
        messages = messages,
        stream = claude_body.stream,
    }

    -- Parameter mapping
    if claude_body.max_tokens then
        oai.max_tokens = claude_body.max_tokens
    end
    if claude_body.temperature then
        oai.temperature = claude_body.temperature
    end
    if claude_body.top_p then
        oai.top_p = claude_body.top_p
    end
    if claude_body.top_k then
        oai.top_k = claude_body.top_k
    end
    if claude_body.stop_sequences then
        oai.stop = claude_body.stop_sequences
    end
    if claude_body.metadata then
        oai.metadata = claude_body.metadata
    end

    -- Tool choice
    if claude_body.tool_choice then
        if type(claude_body.tool_choice) == "string" then
            if claude_body.tool_choice == "any" then
                oai.tool_choice = "required"
            elseif claude_body.tool_choice == "none" then
                oai.tool_choice = "none"
            else
                oai.tool_choice = claude_body.tool_choice
            end
        elseif type(claude_body.tool_choice) == "table" then
            if claude_body.tool_choice.type == "tool" and claude_body.tool_choice.name then
                oai.tool_choice = {
                    type = "function",
                    ["function"] = {name = claude_body.tool_choice.name}
                }
            end
        end
    end

    -- Tools
    if claude_body.tools and #claude_body.tools > 0 then
        oai.tools = {}
        for _, tool in ipairs(claude_body.tools) do
            oai.tools[#oai.tools + 1] = {
                type = "function",
                ["function"] = {
                    name = tool.name,
                    description = tool.description,
                    parameters = tool.input_schema,
                }
            }
        end
    end

    -- Thinking/extended thinking
    if claude_body.thinking then
        oai.thinking = claude_body.thinking
    end

    return oai
end

--- Convert user message content blocks
function _M._convert_user_message(msg, messages)
    local text_parts = {}
    local has_images = false
    local multipart = {}

    for _, block in ipairs(msg.content) do
        if type(block) == "string" then
            text_parts[#text_parts + 1] = block
            multipart[#multipart + 1] = {type = "text", text = block}
        elseif block.type == "text" then
            text_parts[#text_parts + 1] = block.text
            multipart[#multipart + 1] = {type = "text", text = block.text}
        elseif block.type == "image" then
            has_images = true
            local url
            if block.source and block.source.type == "base64" then
                url = "data:" .. (block.source.media_type or "image/png") .. ";base64," .. block.source.data
            elseif block.source and block.source.type == "url" then
                url = block.source.url
            end
            if url then
                multipart[#multipart + 1] = {
                    type = "image_url",
                    image_url = {url = url}
                }
            end
        elseif block.type == "tool_result" then
            -- tool_result blocks become separate tool messages
            local content_text
            if type(block.content) == "string" then
                content_text = block.content
            elseif type(block.content) == "table" then
                local parts = {}
                for _, part in ipairs(block.content) do
                    if type(part) == "string" then
                        parts[#parts + 1] = part
                    elseif part.type == "text" then
                        parts[#parts + 1] = part.text
                    else
                        parts[#parts + 1] = cjson.encode(part)
                    end
                end
                content_text = table.concat(parts, "\n")
            else
                content_text = ""
            end
            messages[#messages + 1] = {
                role = "tool",
                content = content_text,
                tool_call_id = block.tool_use_id,
            }
        end
    end

    -- Add the user content (if any text/image blocks exist)
    if has_images then
        messages[#messages + 1] = {role = "user", content = multipart}
    elseif #text_parts > 0 then
        messages[#messages + 1] = {role = "user", content = table.concat(text_parts, "\n")}
    end
end

--- Convert assistant message content blocks
function _M._convert_assistant_message(msg, messages)
    local content_str = ""
    local tool_calls = {}

    for _, block in ipairs(msg.content) do
        if block.type == "thinking" and block.thinking then
            content_str = "<think>" .. block.thinking .. "</think>" .. content_str
        elseif block.type == "text" then
            content_str = content_str .. (block.text or "")
        elseif block.type == "tool_use" then
            local args = block.input
            if type(args) == "table" then
                args = cjson.encode(args)
            end
            tool_calls[#tool_calls + 1] = {
                id = block.id,
                type = "function",
                ["function"] = {
                    name = block.name,
                    arguments = args or "{}",
                }
            }
        end
    end

    local oai_msg = {role = "assistant", content = content_str}
    if #tool_calls > 0 then
        oai_msg.tool_calls = tool_calls
    end
    messages[#messages + 1] = oai_msg
end

--- Map OpenAI finish_reason to Claude stop_reason
local function map_stop_reason(finish_reason)
    if finish_reason == "stop" then return "end_turn"
    elseif finish_reason == "length" then return "max_tokens"
    elseif finish_reason == "tool_calls" or finish_reason == "function_call" then return "tool_use"
    elseif finish_reason == "content_filter" then return "end_turn"
    else return "end_turn"
    end
end

--- Convert OpenAI Chat Completion response to Claude Messages response (non-streaming)
function _M.response_from_openai(openai_resp, model)
    local resp = type(openai_resp) == "string" and cjson.decode(openai_resp) or openai_resp
    if not resp then return nil end

    local choice = resp.choices and resp.choices[1]
    if not choice then return nil end

    local message = choice.message or {}
    local content_blocks = {}

    local text = message.content or ""

    -- Check for <think>...</think> prefix
    local think_text, remaining = text:match("^<think>(.-)</think>(.*)$")
    if think_text then
        content_blocks[#content_blocks + 1] = {
            type = "thinking",
            thinking = think_text,
        }
        text = remaining
    end

    -- Text block
    if text and text ~= "" then
        content_blocks[#content_blocks + 1] = {
            type = "text",
            text = text,
        }
    end

    -- Tool calls
    if type(message.tool_calls) == "table" then
        for _, tc in ipairs(message.tool_calls) do
            local input = cjson.decode(tc["function"].arguments or "{}")
            content_blocks[#content_blocks + 1] = {
                type = "tool_use",
                id = tc.id,
                name = tc["function"].name,
                input = input or {},
            }
        end
    end

    -- If no content at all, add empty text block
    if #content_blocks == 0 then
        content_blocks[#content_blocks + 1] = {type = "text", text = ""}
    end

    local stop_reason = map_stop_reason(choice.finish_reason)
    if type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        stop_reason = "tool_use"
    end

    local usage = {}
    if type(resp.usage) == "table" then
        usage = {
            input_tokens = resp.usage.prompt_tokens or 0,
            output_tokens = resp.usage.completion_tokens or 0,
        }
    end

    return {
        id = "msg_" .. (resp.id or ngx.now()),
        type = "message",
        role = "assistant",
        content = content_blocks,
        model = model or resp.model or "unknown",
        stop_reason = stop_reason,
        stop_sequence = cjson.null,
        usage = usage,
    }
end

-- ============= Streaming =============

--- Create new streaming state
function _M.new_stream_state(model)
    return {
        model = model or "unknown",
        block_index = 0,
        current_type = nil,       -- "thinking", "text", "tool_use"
        think_buffer = "",        -- buffer for <think> detection
        think_detecting = false,  -- actively detecting <think>
        think_detected = false,   -- confirmed thinking block
        text_started = false,
        tool_states = {},         -- [tc_index] = {id, name, block_index, started}
        usage = {input_tokens = 0, output_tokens = 0},
        stop_reason = "end_turn",
        message_started = false,
        first_content = true,     -- first content delta
    }
end

--- Emit a Claude SSE event
local function sse_event(event_type, data)
    return "event: " .. event_type .. "\ndata: " .. encode_with_empty_arrays(data) .. "\n\n"
end

--- Process a single OpenAI streaming chunk, return array of Claude SSE event strings
function _M.stream_chunk_from_openai(state, chunk_line)
    local events = {}

    -- Parse the chunk - it might be a raw data line or just JSON
    local json_str = chunk_line
    if chunk_line:match("^data: ") then
        json_str = chunk_line:sub(7)
    end
    json_str = json_str:match("^%s*(.-)%s*$")

    if json_str == "[DONE]" or json_str == "" then
        return events
    end

    local chunk = cjson.decode(json_str)
    if not chunk then return events end

    -- Emit message_start on first chunk
    if not state.message_started then
        state.message_started = true
        if chunk.model then state.model = chunk.model end
        events[#events + 1] = sse_event("message_start", {
            type = "message_start",
            message = {
                id = "msg_" .. (chunk.id or ngx.now()),
                type = "message",
                role = "assistant",
                content = {},
                model = state.model,
                stop_reason = cjson.null,
                stop_sequence = cjson.null,
                usage = {input_tokens = state.usage.input_tokens, output_tokens = 0},
            }
        })
    end

    -- Track usage
    if type(chunk.usage) == "table" then
        if chunk.usage.prompt_tokens then
            state.usage.input_tokens = chunk.usage.prompt_tokens
        end
        if chunk.usage.completion_tokens then
            state.usage.output_tokens = chunk.usage.completion_tokens
        end
    end

    local choice = chunk.choices and chunk.choices[1]
    if not choice then return events end

    local delta = choice.delta or {}

    -- Track finish reason
    if type(choice.finish_reason) == "string" then
        state.stop_reason = map_stop_reason(choice.finish_reason)
        if type(delta.tool_calls) == "table" or (state.tool_states and next(state.tool_states)) then
            state.stop_reason = "tool_use"
        end
    end

    -- Handle content delta
    if type(delta.content) == "string" and delta.content ~= "" then
        local content = delta.content

        if state.first_content then
            state.first_content = false
            state.think_detecting = true
            state.think_buffer = ""
        end

        if state.think_detecting then
            state.think_buffer = state.think_buffer .. content
            -- Check if we have enough to determine
            if state.think_buffer:sub(1, 7) == "<think>" then
                if #state.think_buffer >= 7 then
                    state.think_detecting = false
                    state.think_detected = true
                    -- Start thinking block
                    state.current_type = "thinking"
                    events[#events + 1] = sse_event("content_block_start", {
                        type = "content_block_start",
                        index = state.block_index,
                        content_block = {type = "thinking", thinking = ""},
                    })
                    -- Emit any buffered content after <think>
                    local after = state.think_buffer:sub(8)
                    if after ~= "" then
                        events[#events + 1] = sse_event("content_block_delta", {
                            type = "content_block_delta",
                            index = state.block_index,
                            delta = {type = "thinking_delta", thinking = after},
                        })
                    end
                end
                -- else keep buffering
            else
                -- Not <think>, flush buffer as text
                state.think_detecting = false
                state.current_type = "text"
                state.text_started = true
                events[#events + 1] = sse_event("content_block_start", {
                    type = "content_block_start",
                    index = state.block_index,
                    content_block = {type = "text", text = ""},
                })
                events[#events + 1] = sse_event("content_block_delta", {
                    type = "content_block_delta",
                    index = state.block_index,
                    delta = {type = "text_delta", text = state.think_buffer},
                })
            end
        elseif state.think_detected and state.current_type == "thinking" then
            -- Check for </think> in the content
            local before, after = content:match("^(.-)</think>(.*)$")
            if before ~= nil then
                -- End of thinking
                if before ~= "" then
                    events[#events + 1] = sse_event("content_block_delta", {
                        type = "content_block_delta",
                        index = state.block_index,
                        delta = {type = "thinking_delta", thinking = before},
                    })
                end
                events[#events + 1] = sse_event("content_block_stop", {
                    type = "content_block_stop",
                    index = state.block_index,
                })
                state.block_index = state.block_index + 1

                -- Start text block
                state.current_type = "text"
                state.text_started = true
                events[#events + 1] = sse_event("content_block_start", {
                    type = "content_block_start",
                    index = state.block_index,
                    content_block = {type = "text", text = ""},
                })
                if after and after ~= "" then
                    events[#events + 1] = sse_event("content_block_delta", {
                        type = "content_block_delta",
                        index = state.block_index,
                        delta = {type = "text_delta", text = after},
                    })
                end
            else
                -- Still in thinking
                events[#events + 1] = sse_event("content_block_delta", {
                    type = "content_block_delta",
                    index = state.block_index,
                    delta = {type = "thinking_delta", thinking = content},
                })
            end
        else
            -- Regular text
            if not state.text_started then
                state.text_started = true
                state.current_type = "text"
                events[#events + 1] = sse_event("content_block_start", {
                    type = "content_block_start",
                    index = state.block_index,
                    content_block = {type = "text", text = ""},
                })
            end
            events[#events + 1] = sse_event("content_block_delta", {
                type = "content_block_delta",
                index = state.block_index,
                delta = {type = "text_delta", text = content},
            })
        end
    end

    -- Handle tool calls
    if type(delta.tool_calls) == "table" then
        for _, tc in ipairs(delta.tool_calls) do
            local idx = tc.index or 0
            if not state.tool_states[idx] then
                -- Close current text block if open
                if state.text_started and state.current_type == "text" then
                    events[#events + 1] = sse_event("content_block_stop", {
                        type = "content_block_stop",
                        index = state.block_index,
                    })
                    state.block_index = state.block_index + 1
                    state.text_started = false
                    state.current_type = nil
                elseif state.current_type == "thinking" then
                    events[#events + 1] = sse_event("content_block_stop", {
                        type = "content_block_stop",
                        index = state.block_index,
                    })
                    state.block_index = state.block_index + 1
                    state.current_type = nil
                end

                state.tool_states[idx] = {
                    id = tc.id,
                    name = tc["function"] and tc["function"].name,
                    block_index = state.block_index,
                    started = false,
                    pending_args = "",
                }
            end

            local ts = state.tool_states[idx]

            -- Update id/name if provided
            if tc.id then ts.id = tc.id end
            if tc["function"] and tc["function"].name then
                ts.name = tc["function"].name
            end

            -- Accumulate arguments
            if tc["function"] and tc["function"].arguments then
                ts.pending_args = ts.pending_args .. tc["function"].arguments
            end

            -- Emit start once we have id and name
            if not ts.started and ts.id and ts.name then
                ts.started = true
                events[#events + 1] = sse_event("content_block_start", {
                    type = "content_block_start",
                    index = ts.block_index,
                    content_block = {
                        type = "tool_use",
                        id = ts.id,
                        name = ts.name,
                        input = {},
                    },
                })
                -- Flush any pending args
                if ts.pending_args ~= "" then
                    events[#events + 1] = sse_event("content_block_delta", {
                        type = "content_block_delta",
                        index = ts.block_index,
                        delta = {type = "input_json_delta", partial_json = ts.pending_args},
                    })
                    ts.pending_args = ""
                end
            elseif ts.started and tc["function"] and tc["function"].arguments then
                events[#events + 1] = sse_event("content_block_delta", {
                    type = "content_block_delta",
                    index = ts.block_index,
                    delta = {type = "input_json_delta", partial_json = tc["function"].arguments},
                })
            end
        end
    end

    return events
end

--- Finalize the stream, return closing events
function _M.stream_end(state)
    local events = {}

    -- Close any open blocks
    if state.think_detecting and state.think_buffer ~= "" then
        -- Flush as text
        events[#events + 1] = sse_event("content_block_start", {
            type = "content_block_start",
            index = state.block_index,
            content_block = {type = "text", text = ""},
        })
        events[#events + 1] = sse_event("content_block_delta", {
            type = "content_block_delta",
            index = state.block_index,
            delta = {type = "text_delta", text = state.think_buffer},
        })
        events[#events + 1] = sse_event("content_block_stop", {
            type = "content_block_stop",
            index = state.block_index,
        })
    elseif state.current_type == "text" and state.text_started then
        events[#events + 1] = sse_event("content_block_stop", {
            type = "content_block_stop",
            index = state.block_index,
        })
    elseif state.current_type == "thinking" then
        events[#events + 1] = sse_event("content_block_stop", {
            type = "content_block_stop",
            index = state.block_index,
        })
    end

    -- Close open tool blocks
    for _, ts in pairs(state.tool_states) do
        if ts.started then
            events[#events + 1] = sse_event("content_block_stop", {
                type = "content_block_stop",
                index = ts.block_index,
            })
        end
    end

    -- message_delta with stop reason
    events[#events + 1] = sse_event("message_delta", {
        type = "message_delta",
        delta = {stop_reason = state.stop_reason, stop_sequence = cjson.null},
        usage = {input_tokens = state.usage.input_tokens, output_tokens = state.usage.output_tokens},
    })

    -- message_stop
    events[#events + 1] = sse_event("message_stop", {type = "message_stop"})

    return events
end

return _M
