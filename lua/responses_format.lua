--
-- responses_format.lua - OpenAI Responses API <-> Chat Completions translation
--

local cjson = require("cjson.safe")

local _M = {}

local cjson_encode = cjson.encode

-- Encode and patch known empty-object fields that should be arrays
local function encode_with_empty_arrays(obj)
    local json = cjson_encode(obj)
    if not json then return nil end
    json = json:gsub('"content":{}', '"content":[]')
    json = json:gsub('"output":{}', '"output":[]')
    json = json:gsub('"annotations":{}', '"annotations":[]')
    return json
end

--- Generate a unique response ID
local function gen_response_id()
    return "resp_" .. string.format("%x", math.floor(ngx.now() * 1000)) .. string.format("%04x", math.random(0, 65535))
end

--- Generate a unique item ID
local function gen_item_id()
    return "item_" .. string.format("%x", math.floor(ngx.now() * 1000)) .. string.format("%04x", math.random(0, 65535))
end

--- Convert Responses API request to Chat Completions request
function _M.request_to_openai(resp_body)
    local messages = {}

    -- Instructions -> system message
    if resp_body.instructions and resp_body.instructions ~= "" then
        messages[#messages + 1] = {role = "system", content = resp_body.instructions}
    end

    -- Input conversion
    if resp_body.input then
        if type(resp_body.input) == "string" then
            messages[#messages + 1] = {role = "user", content = resp_body.input}
        elseif type(resp_body.input) == "table" then
            local pending_tool_calls = {}
            local pending_reasoning = ""

            for _, item in ipairs(resp_body.input) do
                if item.type == "message" then
                    local role = item.role or "user"
                    local content = _M._convert_response_content(item.content)

                    if role == "assistant" then
                        local msg = {role = "assistant", content = content}
                        -- Attach any pending tool calls
                        if #pending_tool_calls > 0 then
                            msg.tool_calls = pending_tool_calls
                            pending_tool_calls = {}
                        end
                        -- Prepend pending reasoning as <think> tags
                        if pending_reasoning ~= "" then
                            local c = msg.content or ""
                            msg.content = "<think>" .. pending_reasoning .. "</think>" .. c
                            pending_reasoning = ""
                        end
                        messages[#messages + 1] = msg
                    else
                        messages[#messages + 1] = {role = role, content = content}
                    end

                elseif item.type == "function_call" then
                    pending_tool_calls[#pending_tool_calls + 1] = {
                        id = item.call_id or item.id or "",
                        type = "function",
                        ["function"] = {
                            name = item.name or "",
                            arguments = item.arguments or "{}",
                        }
                    }

                elseif item.type == "function_call_output" then
                    -- If there are pending tool calls, flush them as an assistant message first
                    if #pending_tool_calls > 0 then
                        local msg = {role = "assistant", content = ""}
                        msg.tool_calls = pending_tool_calls
                        if pending_reasoning ~= "" then
                            msg.content = "<think>" .. pending_reasoning .. "</think>"
                            pending_reasoning = ""
                        end
                        messages[#messages + 1] = msg
                        pending_tool_calls = {}
                    end

                    local output = item.output or ""
                    -- If output is a JSON object with an "output" key, extract the inner string
                    if type(output) == "table" and output.output then
                        output = output.output
                    end
                    if type(output) == "table" then
                        output = cjson.encode(output)
                    end

                    messages[#messages + 1] = {
                        role = "tool",
                        content = tostring(output),
                        tool_call_id = item.call_id or item.id or "",
                    }

                elseif item.type == "reasoning" then
                    -- Accumulate reasoning for next assistant message
                    if item.text then
                        pending_reasoning = pending_reasoning .. item.text
                    end
                end
            end

            -- Flush any remaining pending tool calls
            if #pending_tool_calls > 0 then
                local msg = {role = "assistant", content = ""}
                msg.tool_calls = pending_tool_calls
                if pending_reasoning ~= "" then
                    msg.content = "<think>" .. pending_reasoning .. "</think>"
                end
                messages[#messages + 1] = msg
            end
        end
    end

    -- If messages field is provided directly (hybrid mode), use as-is
    if resp_body.messages and not resp_body.input then
        messages = resp_body.messages
    end

    -- Build OpenAI request
    local oai = {
        model = resp_body.model,
        messages = messages,
        stream = resp_body.stream,
    }

    -- Parameter mapping
    if resp_body.max_output_tokens then
        oai.max_tokens = resp_body.max_output_tokens
    elseif resp_body.max_tokens then
        oai.max_tokens = resp_body.max_tokens
    end
    if resp_body.temperature then oai.temperature = resp_body.temperature end
    if resp_body.top_p then oai.top_p = resp_body.top_p end
    if resp_body.stop then oai.stop = resp_body.stop end
    if resp_body.frequency_penalty then oai.frequency_penalty = resp_body.frequency_penalty end
    if resp_body.presence_penalty then oai.presence_penalty = resp_body.presence_penalty end
    if resp_body.seed then oai.seed = resp_body.seed end
    if resp_body.metadata then oai.metadata = resp_body.metadata end
    if resp_body.reasoning_effort then oai.reasoning_effort = resp_body.reasoning_effort end
    if resp_body.parallel_tool_calls ~= nil then oai.parallel_tool_calls = resp_body.parallel_tool_calls end

    -- Tool choice passthrough
    if resp_body.tool_choice then
        oai.tool_choice = resp_body.tool_choice
    end

    -- Tools - filter to function type only
    if resp_body.tools and #resp_body.tools > 0 then
        oai.tools = {}
        for _, tool in ipairs(resp_body.tools) do
            if tool.type == "function" then
                if tool["function"] then
                    -- Nested format
                    oai.tools[#oai.tools + 1] = tool
                else
                    -- Flat format
                    oai.tools[#oai.tools + 1] = {
                        type = "function",
                        ["function"] = {
                            name = tool.name,
                            description = tool.description,
                            parameters = tool.parameters,
                        }
                    }
                end
            end
        end
        if #oai.tools == 0 then oai.tools = nil end
    end

    return oai
end

--- Convert response content (string or array of parts) to a simple string
function _M._convert_response_content(content)
    if type(content) == "string" then
        return content
    elseif type(content) == "table" then
        local parts = {}
        for _, part in ipairs(content) do
            if type(part) == "string" then
                parts[#parts + 1] = part
            elseif part.type == "input_text" or part.type == "output_text" then
                parts[#parts + 1] = part.text or ""
            elseif part.type == "text" then
                parts[#parts + 1] = part.text or ""
            else
                -- Pass through other types as JSON
                parts[#parts + 1] = cjson.encode(part)
            end
        end
        return table.concat(parts, "\n")
    end
    return ""
end

--- Map finish_reason to Responses API status
local function map_status(finish_reason)
    if finish_reason == "stop" or finish_reason == "tool_calls" then return "completed"
    elseif finish_reason == "length" then return "incomplete"
    elseif finish_reason == "content_filter" then return "failed"
    else return "completed"
    end
end

--- Convert Chat Completions response to Responses API response (non-streaming)
function _M.response_from_openai(openai_resp, model, request)
    local resp = type(openai_resp) == "string" and cjson.decode(openai_resp) or openai_resp
    if not resp then return nil end

    local choice = resp.choices and resp.choices[1]
    if not choice then return nil end

    local message = choice.message or {}
    local output = {}

    local text = message.content or ""

    -- Check for <think>...</think> prefix
    local think_text, remaining = text:match("^<think>(.-)</think>(.*)$")
    if think_text then
        output[#output + 1] = {
            type = "reasoning",
            id = gen_item_id(),
            object = "realtime.item",
            status = "completed",
            text = think_text,
        }
        text = remaining
    end

    -- Message output item
    local msg_item = {
        type = "message",
        id = gen_item_id(),
        object = "realtime.item",
        status = "completed",
        role = "assistant",
        content = {},
    }

    if text and text ~= "" then
        msg_item.content[#msg_item.content + 1] = {
            type = "output_text",
            text = text,
            annotations = {},
        }
    end

    output[#output + 1] = msg_item

    -- Tool calls -> function_call output items
    if type(message.tool_calls) == "table" then
        for _, tc in ipairs(message.tool_calls) do
            output[#output + 1] = {
                type = "function_call",
                id = gen_item_id(),
                object = "realtime.item",
                status = "completed",
                call_id = tc.id,
                name = tc["function"].name,
                arguments = tc["function"].arguments or "{}",
            }
        end
    end

    local status = map_status(choice.finish_reason)

    local usage = {}
    if type(resp.usage) == "table" then
        usage = {
            input_tokens = resp.usage.prompt_tokens or 0,
            output_tokens = resp.usage.completion_tokens or 0,
            total_tokens = (resp.usage.prompt_tokens or 0) + (resp.usage.completion_tokens or 0),
        }
    end

    local response = {
        id = gen_response_id(),
        object = "response",
        status = status,
        model = model or resp.model or "unknown",
        output = output,
        usage = usage,
        created_at = math.floor(ngx.now()),
    }

    if status == "incomplete" then
        response.incomplete_details = {reason = "max_output_tokens"}
    end

    return response
end

-- ============= Streaming =============

--- Create new streaming state
function _M.new_stream_state(model)
    local resp_id = gen_response_id()
    return {
        model = model or "unknown",
        response_id = resp_id,
        seq = 0,
        msg_item_id = gen_item_id(),
        output_index = 0,
        content_index = 0,
        tool_states = {},     -- [tc_index] = {item_id, call_id, name, args, started, output_index}
        next_output_index = 1, -- next output index for tool calls (0 = message)
        usage = {input_tokens = 0, output_tokens = 0, total_tokens = 0},
        status = "completed",
        accumulated_text = "",
        first_content = true,
        think_buffer = "",
        think_detecting = false,
        think_detected = false,
        reasoning_item_id = nil,
        reasoning_text = "",
        message_started = false, -- whether message output_item.added has been emitted
        text_part_started = false, -- whether content_part.added has been emitted
        response_created = false,
    }
end

--- Get next sequence number
local function next_seq(state)
    state.seq = state.seq + 1
    return state.seq
end

--- Build a stream event
local function stream_event(state, event_type, extra)
    local evt = {
        type = event_type,
        event_id = string.format("evt_%s_%04x", state.response_id, next_seq(state)),
        response_id = state.response_id,
        sequence_number = state.seq,
    }
    if extra then
        for k, v in pairs(extra) do
            evt[k] = v
        end
    end
    return "event: " .. event_type .. "\ndata: " .. encode_with_empty_arrays(evt) .. "\n\n"
end

--- Ensure the message output item has been started
local function ensure_message_started(state, events)
    if state.message_started then return end
    state.message_started = true

    -- output_item.added for the message
    events[#events + 1] = stream_event(state, "response.output_item.added", {
        output_index = state.output_index,
        item = {
            type = "message",
            id = state.msg_item_id,
            object = "realtime.item",
            status = "in_progress",
            role = "assistant",
            content = {},
        },
    })
end

--- Ensure the text content part has been started
local function ensure_text_part_started(state, events)
    ensure_message_started(state, events)
    if state.text_part_started then return end
    state.text_part_started = true

    events[#events + 1] = stream_event(state, "response.content_part.added", {
        item_id = state.msg_item_id,
        output_index = state.output_index,
        content_index = state.content_index,
        part = {type = "output_text", text = "", annotations = {}},
    })
end

--- Process a single OpenAI streaming chunk, return array of Responses SSE event strings
function _M.stream_chunk_from_openai(state, chunk_line)
    local events = {}

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

    -- Emit response.created on first chunk
    if not state.response_created then
        state.response_created = true
        if chunk.model then state.model = chunk.model end
        events[#events + 1] = stream_event(state, "response.created", {
            response = {
                id = state.response_id,
                object = "response",
                status = "in_progress",
                model = state.model,
                output = {},
                usage = state.usage,
                created_at = math.floor(ngx.now()),
            },
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
        state.usage.total_tokens = state.usage.input_tokens + state.usage.output_tokens
    end

    local choice = chunk.choices and chunk.choices[1]
    if not choice then return events end

    local delta = choice.delta or {}

    -- Track finish reason
    if type(choice.finish_reason) == "string" then
        state.status = map_status(choice.finish_reason)
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
            if state.think_buffer:sub(1, 7) == "<think>" then
                if #state.think_buffer >= 7 then
                    state.think_detecting = false
                    state.think_detected = true
                    state.reasoning_item_id = gen_item_id()
                    -- Emit reasoning output_item.added
                    events[#events + 1] = stream_event(state, "response.output_item.added", {
                        output_index = state.output_index,
                        item = {
                            type = "reasoning",
                            id = state.reasoning_item_id,
                            object = "realtime.item",
                            status = "in_progress",
                            text = "",
                        },
                    })
                    state.next_output_index = state.next_output_index + 1
                    -- Emit any buffered reasoning after <think>
                    local after = state.think_buffer:sub(8)
                    if after ~= "" then
                        state.reasoning_text = state.reasoning_text .. after
                        events[#events + 1] = stream_event(state, "response.reasoning_text.delta", {
                            item_id = state.reasoning_item_id,
                            output_index = state.output_index,
                            delta = after,
                        })
                    end
                end
                -- else keep buffering
            else
                -- Not <think>, flush as text
                state.think_detecting = false
                state.output_index = state.next_output_index - 1
                ensure_text_part_started(state, events)
                state.accumulated_text = state.accumulated_text .. state.think_buffer
                events[#events + 1] = stream_event(state, "response.output_text.delta", {
                    item_id = state.msg_item_id,
                    output_index = state.output_index,
                    content_index = state.content_index,
                    delta = state.think_buffer,
                })
            end
        elseif state.think_detected and not state.text_part_started then
            -- Still in reasoning mode, check for </think>
            local before, after = content:match("^(.-)</think>(.*)$")
            if before ~= nil then
                -- End reasoning
                if before ~= "" then
                    state.reasoning_text = state.reasoning_text .. before
                    events[#events + 1] = stream_event(state, "response.reasoning_text.delta", {
                        item_id = state.reasoning_item_id,
                        output_index = 0,
                        delta = before,
                    })
                end
                -- Close reasoning item
                events[#events + 1] = stream_event(state, "response.reasoning_text.done", {
                    item_id = state.reasoning_item_id,
                    output_index = 0,
                    text = state.reasoning_text,
                })
                events[#events + 1] = stream_event(state, "response.output_item.done", {
                    output_index = 0,
                    item = {
                        type = "reasoning",
                        id = state.reasoning_item_id,
                        object = "realtime.item",
                        status = "completed",
                        text = state.reasoning_text,
                    },
                })

                -- Start text output
                state.output_index = state.next_output_index
                state.next_output_index = state.next_output_index + 1
                if after and after ~= "" then
                    ensure_text_part_started(state, events)
                    state.accumulated_text = state.accumulated_text .. after
                    events[#events + 1] = stream_event(state, "response.output_text.delta", {
                        item_id = state.msg_item_id,
                        output_index = state.output_index,
                        content_index = state.content_index,
                        delta = after,
                    })
                end
            else
                state.reasoning_text = state.reasoning_text .. content
                events[#events + 1] = stream_event(state, "response.reasoning_text.delta", {
                    item_id = state.reasoning_item_id,
                    output_index = 0,
                    delta = content,
                })
            end
        else
            -- Regular text
            if not state.message_started then
                state.output_index = state.next_output_index - 1
            end
            ensure_text_part_started(state, events)
            state.accumulated_text = state.accumulated_text .. content
            events[#events + 1] = stream_event(state, "response.output_text.delta", {
                item_id = state.msg_item_id,
                output_index = state.output_index,
                content_index = state.content_index,
                delta = content,
            })
        end
    end

    -- Handle tool calls
    if type(delta.tool_calls) == "table" then
        for _, tc in ipairs(delta.tool_calls) do
            local idx = tc.index or 0
            if not state.tool_states[idx] then
                state.tool_states[idx] = {
                    item_id = gen_item_id(),
                    call_id = tc.id,
                    name = tc["function"] and tc["function"].name,
                    args = "",
                    started = false,
                    output_index = state.next_output_index,
                }
                state.next_output_index = state.next_output_index + 1
            end

            local ts = state.tool_states[idx]
            if tc.id then ts.call_id = tc.id end
            if tc["function"] and tc["function"].name then
                ts.name = tc["function"].name
            end
            if tc["function"] and tc["function"].arguments then
                ts.args = ts.args .. tc["function"].arguments
            end

            -- Emit start once we have name and call_id
            if not ts.started and ts.name and ts.call_id then
                ts.started = true

                -- Close message text if open
                if state.text_part_started then
                    events[#events + 1] = stream_event(state, "response.output_text.done", {
                        item_id = state.msg_item_id,
                        output_index = state.output_index,
                        content_index = state.content_index,
                        text = state.accumulated_text,
                    })
                    events[#events + 1] = stream_event(state, "response.content_part.done", {
                        item_id = state.msg_item_id,
                        output_index = state.output_index,
                        content_index = state.content_index,
                        part = {type = "output_text", text = state.accumulated_text, annotations = {}},
                    })
                    events[#events + 1] = stream_event(state, "response.output_item.done", {
                        output_index = state.output_index,
                        item = {
                            type = "message",
                            id = state.msg_item_id,
                            object = "realtime.item",
                            status = "completed",
                            role = "assistant",
                            content = {{type = "output_text", text = state.accumulated_text, annotations = {}}},
                        },
                    })
                    state.text_part_started = false
                    state.message_started = false
                end

                events[#events + 1] = stream_event(state, "response.output_item.added", {
                    output_index = ts.output_index,
                    item = {
                        type = "function_call",
                        id = ts.item_id,
                        object = "realtime.item",
                        status = "in_progress",
                        call_id = ts.call_id,
                        name = ts.name,
                        arguments = "",
                    },
                })

                -- Flush pending args
                if ts.args ~= "" then
                    events[#events + 1] = stream_event(state, "response.function_call_arguments.delta", {
                        item_id = ts.item_id,
                        output_index = ts.output_index,
                        call_id = ts.call_id,
                        delta = ts.args,
                    })
                end
            elseif ts.started and tc["function"] and tc["function"].arguments then
                events[#events + 1] = stream_event(state, "response.function_call_arguments.delta", {
                    item_id = ts.item_id,
                    output_index = ts.output_index,
                    call_id = ts.call_id,
                    delta = tc["function"].arguments,
                })
            end
        end
    end

    return events
end

--- Finalize the stream
function _M.stream_end(state)
    local events = {}

    -- Flush think buffer if still detecting
    if state.think_detecting and state.think_buffer ~= "" then
        state.output_index = state.next_output_index - 1
        ensure_text_part_started(state, events)
        state.accumulated_text = state.accumulated_text .. state.think_buffer
        events[#events + 1] = stream_event(state, "response.output_text.delta", {
            item_id = state.msg_item_id,
            output_index = state.output_index,
            content_index = state.content_index,
            delta = state.think_buffer,
        })
    end

    -- Close reasoning if still open
    if state.think_detected and state.reasoning_item_id and not state.text_part_started then
        events[#events + 1] = stream_event(state, "response.reasoning_text.done", {
            item_id = state.reasoning_item_id,
            output_index = 0,
            text = state.reasoning_text,
        })
        events[#events + 1] = stream_event(state, "response.output_item.done", {
            output_index = 0,
            item = {
                type = "reasoning",
                id = state.reasoning_item_id,
                object = "realtime.item",
                status = "completed",
                text = state.reasoning_text,
            },
        })
    end

    -- Build output array for final response
    local output = {}

    -- Close text part if open
    if state.text_part_started then
        events[#events + 1] = stream_event(state, "response.output_text.done", {
            item_id = state.msg_item_id,
            output_index = state.output_index,
            content_index = state.content_index,
            text = state.accumulated_text,
        })
        events[#events + 1] = stream_event(state, "response.content_part.done", {
            item_id = state.msg_item_id,
            output_index = state.output_index,
            content_index = state.content_index,
            part = {type = "output_text", text = state.accumulated_text, annotations = {}},
        })
        events[#events + 1] = stream_event(state, "response.output_item.done", {
            output_index = state.output_index,
            item = {
                type = "message",
                id = state.msg_item_id,
                object = "realtime.item",
                status = "completed",
                role = "assistant",
                content = {{type = "output_text", text = state.accumulated_text, annotations = {}}},
            },
        })

        output[#output + 1] = {
            type = "message",
            id = state.msg_item_id,
            object = "realtime.item",
            status = "completed",
            role = "assistant",
            content = {{type = "output_text", text = state.accumulated_text, annotations = {}}},
        }
    end

    -- Close tool calls
    for _, ts in pairs(state.tool_states) do
        if ts.started then
            events[#events + 1] = stream_event(state, "response.function_call_arguments.done", {
                item_id = ts.item_id,
                output_index = ts.output_index,
                call_id = ts.call_id,
                name = ts.name,
                arguments = ts.args,
            })
            events[#events + 1] = stream_event(state, "response.output_item.done", {
                output_index = ts.output_index,
                item = {
                    type = "function_call",
                    id = ts.item_id,
                    object = "realtime.item",
                    status = "completed",
                    call_id = ts.call_id,
                    name = ts.name,
                    arguments = ts.args,
                },
            })

            output[#output + 1] = {
                type = "function_call",
                id = ts.item_id,
                object = "realtime.item",
                status = "completed",
                call_id = ts.call_id,
                name = ts.name,
                arguments = ts.args,
            }
        end
    end

    -- response.completed
    local final_response = {
        id = state.response_id,
        object = "response",
        status = state.status,
        model = state.model,
        output = output,
        usage = state.usage,
        created_at = math.floor(ngx.now()),
    }

    if state.status == "incomplete" then
        final_response.incomplete_details = {reason = "max_output_tokens"}
    end

    events[#events + 1] = stream_event(state, "response.completed", {
        response = final_response,
    })

    return events
end

_M.encode = encode_with_empty_arrays

return _M
