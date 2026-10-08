-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Headers module.
-- @module apisix.plugins.mcp-proxy.headers
local require = require
local pairs = pairs
local type = type

local table_new = require("table.new")

local table_concat = table.concat

local headers = {}
local HOP_HEADERS = {
    connection = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    te = true,
    trailer = true,
    ["transfer-encoding"] = true,
    upgrade = true,
    ["content-length"] = true,
    ["content-encoding"] = true,
    ["mcp-session-id"] = true,
    ["x-mcp-proxy-ticket"] = true,
}


--- Copy end-to-end headers and remove hop-by-hop or private transport fields.
-- Honors Connection-nominated fields and requests an uncompressed response.
-- @param incoming_headers table Incoming header map; values may be strings or arrays.
-- @return table New lowercase header map; the input is not modified.
function headers.forward(incoming_headers)
    local blocked, result = table_new(0, 16), table_new(0, 16)
    for name in pairs(HOP_HEADERS) do
        blocked[name] = true
    end
    for name, value in pairs(incoming_headers) do
        if name:lower() == "connection" then
            if type(value) == "table" then
                value = table_concat(value, ",")
            end
            for token in value:gmatch("[^,]+") do
                blocked[token:match("^%s*(.-)%s*$"):lower()] = true
            end
        end
    end
    for name, value in pairs(incoming_headers) do
        name = name:lower()
        if not blocked[name] then
            result[name] = value
        end
    end
    result["accept-encoding"] = "identity"
    return result
end
return headers
