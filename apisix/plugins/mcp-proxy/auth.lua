-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Auth module.
-- @module apisix.plugins.mcp-proxy.auth
local require = require
local ipairs = ipairs
local type = type

local table_new = require("table.new")

local table_concat = table.concat
local table_insert = table.insert

local auth = {}
-- Split only at commas outside quoted strings, preserving quoted-pair escapes.


--- Split challenge fields on commas outside quoted strings.
-- Quoted-pair escapes are preserved for later reconstruction.
-- @param value string Combined WWW-Authenticate header value.
-- @return table|nil Ordered fragments, or nil for an unterminated quoted string.
local function parts(value)
    local out, start, quoted, escaped = {}, 1, false, false
    for i = 1, #value do
        local part = value:sub(i, i)
        if escaped then
            escaped = false

        elseif quoted and part == "\\" then
            escaped = true

        elseif part == '"' then
            quoted = not quoted

        elseif part == "," and not quoted then
            out[#out + 1] = value:sub(start, i - 1)
            start = i + 1
        end
    end
    if quoted then
        return nil
    end
    out[#out + 1] = value:sub(start)
    return out
end


--- Replace or add Bearer resource_metadata while preserving other challenges.
-- @param value string|table|nil Header value or repeated header values.
-- @param url string Validated public protected-resource metadata URL.
-- @return string|nil Rebuilt header; nil and a diagnostic string on malformed input.
function auth.challenge(value, url)
    if type(value) == "table" then
        value = table_concat(value, ", ")
    end
    local tokens = parts(value or "")
    if not tokens then
        return nil, "Malformed upstream authentication challenge"
    end
    local challenges = {}
    for _, token in ipairs(tokens) do
        token = token:match("^%s*(.-)%s*$")
        if token ~= "" then
            local scheme, rest = token:match("^([%w!#$%%&'*+.^_`|~-]+)%s+(.*)$")
            if scheme and not rest:match("^=") then
                challenges[#challenges + 1] = { scheme = scheme, args = { rest } }

            elseif token:match("^[%w_-]+$") then
                challenges[#challenges + 1] = { scheme = token, args = {} }

            elseif #challenges > 0 then
                table_insert(challenges[#challenges].args, token)

            else
                return nil, "Malformed upstream authentication challenge"
            end
        end
    end
    local found = false
    for _, part in ipairs(challenges) do
        if part.scheme:lower() == "bearer" then
            found = true
            local args = {}
            for _, arg in ipairs(part.args) do
                if not arg:lower():match("^resource_metadata%s*=") and arg ~= "" then
                    args[#args + 1] = arg
                end
            end
            args[#args + 1] = 'resource_metadata="'
                .. url:gsub("\\", "\\\\"):gsub('"', '\\"')
                .. '"'
            part.args = args
        end
    end
    if not found then
        challenges[#challenges + 1] =
            { scheme = "Bearer", args = { 'resource_metadata="' .. url .. '"' } }
    end
    local result = table_new(#challenges, 0)
    for _, part in ipairs(challenges) do
        result[#result + 1] = part.scheme
            .. (#part.args > 0 and " " .. table_concat(part.args, ", ") or "")
    end
    return table_concat(result, ", ")
end


--- Build public OAuth resource metadata from explicit configuration.
-- Never derives an origin from client-supplied request headers.
-- @param conf table Configuration containing auth_metadata.
-- @return table Metadata response; referenced arrays are not modified.
function auth.metadata(conf)
    local metadata_config = conf.auth_metadata
    return {
        resource = metadata_config.resource,
        authorization_servers = metadata_config.authorization_servers,
        scopes_supported = metadata_config.scopes_supported,
        bearer_methods_supported = { "header" },
    }
end
return auth
