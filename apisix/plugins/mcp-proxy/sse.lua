-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Sse module.
-- @module apisix.plugins.mcp-proxy.sse
local require = require

local json = require("apisix.plugins.mcp-proxy.json")

local json_decode = json.decode
local table_concat = table.concat

local sse = {}


--- Allocate incremental SSE parsing state with bounded line/event storage.
-- @param limit integer Maximum bytes in a line or assembled event.
-- @return table Mutable parser state, private to one upstream response.
function sse.new(limit)
    return { pieces = {}, line_size = 0, data = {}, size = 0, limit = limit, skip_lf = false }
end


--- Consume an SSE fragment and deliver complete JSON events.
-- Handles CR, LF, CRLF and multiline data; retains incomplete lines in state.
-- A failing callback stops parsing immediately and propagates its diagnostic.
-- @param state table Mutable state returned by new.
-- @param chunk string Next response bytes, possibly a partial line.
-- @param emit function Callback(decoded_message, raw_json): success, error string.
-- @return boolean|nil True on success; nil and a diagnostic string on failure.
function sse.feed(state, chunk, emit)
    local position = 1
    while position <= #chunk do
        if state.skip_lf then
            state.skip_lf = false
            if chunk:sub(position, position) == "\n" then
                position = position + 1
            end
        end
        if position > #chunk then
            break
        end
        local ending = chunk:find("[\r\n]", position)
        local piece = chunk:sub(position, ending and ending - 1 or #chunk)
        state.pieces[#state.pieces + 1] = piece
        state.line_size = state.line_size + #piece
        if state.line_size > state.limit then
            return nil, "SSE line exceeds response bound"
        end
        if not ending then
            break
        end
        state.skip_lf = chunk:sub(ending, ending) == "\r"
        position = ending + 1
        local line = table_concat(state.pieces)
        state.pieces = {}
        state.line_size = 0
        if line == "" then
            if #state.data > 0 then
                local raw = table_concat(state.data, "\n")
                local message = json_decode(raw)
                if not message then
                    return nil, "Invalid JSON in SSE event"
                end
                local ok, why = emit(message, raw)
                if not ok then
                    return nil, why
                end
            end
            state.data = {}
            state.size = 0

        elseif line:sub(1, 1) ~= ":" then
            local name, value = line:match("^([^:]+): ?(.*)$")
            if line == "data" then
                name = "data"
                value = ""
            end
            if name == "data" then
                state.size = state.size + #value
                if state.size > state.limit then
                    return nil, "SSE event exceeds response bound"
                end
                state.data[#state.data + 1] = value
            end
        end
    end
    return true
end
return sse
