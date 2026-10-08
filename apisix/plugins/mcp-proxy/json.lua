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


--- Decode JSON using the private codec, preserving null and empty array types.
-- @param value string JSON document.
-- @return any Decoded value, or nil and a diagnostic string on invalid JSON.
function json.decode(value)
    return json_decode(value)
end


--- Encode a value without changing APISIX shared codec options.
-- @param value any JSON-compatible value with array metatables where required.
-- @return string|nil Encoded JSON, or nil and a diagnostic string on failure.
function json.encode(value)
    return json_encode(value)
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
