-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Template module.
-- @module apisix.plugins.mcp-proxy.template
local type = type

local table_concat = table.concat

-- RFC 6570 restricted scalar profile: simple {var}, one variable per expression.
-- Unsupported operators, lists, prefixes and explode modifiers are rejected.
local template = {}


--- Compile the restricted scalar URI-template profile into a Lua pattern.
-- Accepts simple single-variable expressions; rejects operators and modifiers.
-- @param uri_template string Resource URI template to validate.
-- @return string|nil Anchored Lua pattern, or nil and a diagnostic string.
function template.compile(uri_template)
    if type(uri_template) ~= "string" then
        return nil, "Invalid URI template"
    end
    local pieces, pos = {}, 1
    while pos <= #uri_template do
        local first, last, name = uri_template:find("{([^{}]+)}", pos)
        local literal = first and uri_template:sub(pos, first - 1) or uri_template:sub(pos)
        if literal:find("[{}]") then
            return nil, "Malformed URI template"
        end
        pieces[#pieces + 1] = literal:gsub("([^%w])", "%%%1")
        if not first then
            break
        end
        if not name:match("^[%w_][%w_.]*$") then
            return nil, "Unsupported URI template: only scalar {var} expressions are supported"
        end
        pieces[#pieces + 1] = "([%w_.~%%%-]*)"
        pos = last + 1
    end
    return "^" .. table_concat(pieces) .. "$"
end


--- Match a concrete URI while rejecting malformed percent encodings.
-- @param pattern string Validated pattern returned by compile.
-- @param uri string Concrete resource URI.
-- @return boolean Whether the URI matches the supported template profile.
function template.is_match(pattern, uri)
    for position in uri:gmatch("%%()") do
        if not uri:sub(position, position + 1):match("^%x%x$") then
            return false
        end
    end
    return uri:match(pattern) ~= nil
end
return template
