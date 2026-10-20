-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Json module.
-- @module apisix.plugins.mcp-proxy.json
local require = require
local assert = assert
local getmetatable = getmetatable
local ipairs = ipairs
local pairs = pairs
local setmetatable = setmetatable
local type = type

local table_new = require("table.new")
-- A private codec: never change APISIX's shared cjson instance.
local codec = require("cjson.safe").new()

local json_decode = codec.decode
local json_decode_array_with_array_mt = codec.decode_array_with_array_mt
local json_decode_invalid_numbers = codec.decode_invalid_numbers
local json_encode = codec.encode
local json_encode_empty_table_as_object = codec.encode_empty_table_as_object
local json_encode_invalid_numbers = codec.encode_invalid_numbers
local json_encode_number_precision = codec.encode_number_precision
local table_concat = table.concat
local table_sort = table.sort

json_decode_array_with_array_mt(true)
json_encode_empty_table_as_object(true)
json_decode_invalid_numbers(false)
json_encode_invalid_numbers(false)
json_encode_number_precision(16)
local json = { null = codec.null }
-- Worker-local numeric source fragments are isolated by decoded container identity.
-- Weak keys release entries when their containers are garbage-collected.
local number_sources = setmetatable({}, { __mode = "k" })


--- Find the end of a string in an already validated JSON document.
-- @param source string Valid JSON source.
-- @param position integer Position of its opening quote.
-- @return integer Position immediately after the closing quote.
local function string_end(source, position)
    position = position + 1
    while true do
        local ending = source:find('["\\]', position)
        if source:sub(ending, ending) == '"' then
            return ending + 1
        end
        position = ending + 2
    end
end


--- Walk validated JSON and retain or restore numeric text by container and key.
-- cjson remains responsible for syntax, depth and value validation. This walker
-- never changes decoded types, and restoration only applies to unchanged values.
-- @param state table Source, mode, replacement fragments and output cursor.
-- @param position integer Start position of a JSON value, possibly whitespace.
-- @param parent table|nil Decoded parent container, or nil at the document root.
-- @param key string|integer|nil Property name or array index in the parent.
-- @return integer Position immediately after the JSON value.
local function walk_numbers(state, position, parent, key)
    local source = state.source
    position = source:find("%S", position)
    local char = source:sub(position, position)
    local value = parent and parent[key]
    if char == "{" or char == "[" then
        local container = type(value) == "table" and value or nil
        if state.capture and container then
            number_sources[container] = nil
        end
        local ending = char == "{" and "}" or "]"
        local index = 1
        position = source:find("%S", position + 1)
        while source:sub(position, position) ~= ending do
            local child_key = index
            if char == "{" then
                local last = string_end(source, position)
                child_key = json_decode(source:sub(position, last - 1))
                position = source:find("%S", last) + 1
            end
            position = walk_numbers(state, position, container, child_key)
            position = source:find("%S", position)
            if source:sub(position, position) == "," then
                position = source:find("%S", position + 1)
            end
            index = index + 1
        end
        return position + 1
    end
    if state.capture and parent and number_sources[parent] then
        -- Last duplicate object key wins, including a later nonnumeric value.
        number_sources[parent][key] = nil
    end
    if char == '"' then
        return string_end(source, position)
    end
    local ending = source:find("[,}%]%s]", position) or (#source + 1)
    if char == "-" or char:match("%d") then
        if state.capture and parent and type(value) == "number" then
            local raw = source:sub(position, ending - 1)
            if raw ~= json_encode(value) then
                local entries = number_sources[parent] or {}
                entries[key] = { value = value, raw = raw }
                number_sources[parent] = entries
            end

        elseif not state.capture and parent then
            local entry = number_sources[parent] and number_sources[parent][key]
            if entry and entry.value == value then
                local parts = state.parts
                parts[#parts + 1] = source:sub(state.cursor, position - 1)
                parts[#parts + 1] = entry.raw
                state.cursor = ending
            end
        end
    end
    return ending
end


--- Decode JSON using the private codec, preserving null and empty array types.
-- Records original numeric text on containers when cjson would change it.
-- @param value string JSON document.
-- @return any Decoded value, or nil and a diagnostic string on invalid JSON.
--         Table results may record numeric fragments in worker-local weak-key state.
function json.decode(value)
    local decoded, err = json_decode(value)
    if type(decoded) == "table" then
        walk_numbers({ source = value, capture = true }, 1, { decoded }, 1)
    end
    return decoded, err
end


--- Encode a value without changing APISIX shared codec options.
-- Restores source numeric text for unchanged fields in decoded containers.
-- @param value any JSON-compatible value with array metatables where required.
-- @return string|nil Encoded JSON, or nil and a diagnostic string on failure.
--         Reads worker-local numeric-source state for unchanged container fields.
function json.encode(value)
    local encoded, err = json_encode(value)
    if not encoded or type(value) ~= "table" then
        return encoded, err
    end
    local state = { source = encoded, parts = {}, cursor = 1 }
    walk_numbers(state, 1, { value }, 1)
    state.parts[#state.parts + 1] = encoded:sub(state.cursor)
    return table_concat(state.parts)
end


--- Mark a table as a JSON array, including when it is empty.
-- Mutates the supplied table metatable; allocates a table when omitted.
-- @param value table|nil Array storage, or nil for a new empty array.
-- @return table The supplied or newly allocated array.
function json.array(value)
    return setmetatable(value or {}, codec.array_mt)
end


--- Check whether a value carries the private codec array metatable.
-- @param value any Value to inspect.
-- @return boolean True only for a marked JSON array.
function json.is_array(value)
    return type(value) == "table" and getmetatable(value) == codec.array_mt
end


--- Check whether a value is an object table rather than a JSON array.
-- @param value any Value to inspect.
-- @return boolean True for a table without the JSON array metatable.
function json.is_object(value)
    return type(value) == "table" and not json.is_array(value)
end
-- Canonical encoding is only for routing fingerprints, never wire payloads.


--- Encode routing fingerprint input with sorted object keys.
-- Preserves array order; this representation is never used for wire responses.
-- Raises on values that cannot be encoded or keys that cannot be sorted.
-- @param value any Acyclic JSON-compatible value with string object keys.
-- @return string Deterministic JSON representation.
function json.canonical(value)
    if type(value) ~= "table" then
        return assert(json_encode(value))
    end
    local parts = table_new(#value, 0)
    if json.is_array(value) then
        for i, item in ipairs(value) do
            parts[i] = json.canonical(item)
        end
        return "[" .. table_concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table_sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = assert(json_encode(key)) .. ":" .. json.canonical(value[key])
    end
    return "{" .. table_concat(parts, ",") .. "}"
end
return json
