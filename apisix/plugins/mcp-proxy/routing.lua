-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Routing module.
-- @module apisix.plugins.mcp-proxy.routing
local require = require
local ipairs = ipairs
local pairs = pairs
local tostring = tostring

local json = require("apisix.plugins.mcp-proxy.json")
local sha256 = require("resty.sha256")
local resty_string = require("resty.string")
local upstream = require("apisix.upstream")
local template = require("apisix.plugins.mcp-proxy.template")
local discovery = require("apisix.plugins.mcp-proxy.discovery")
local headers = require("apisix.plugins.mcp-proxy.headers")
local cache = require("resty.lrucache").new(256)

local discovery_fetch = discovery.fetch
local headers_forward = headers.forward
local json_canonical = json.canonical
local resty_string_to_hex = resty_string.to_hex
local template_compile = template.compile
local template_is_match = template.is_match
local upstream_get_by_id = upstream.get_by_id

local ngx_now = ngx.now
local json_encode = json.encode
local routing = {}


--- Hash configuration generations, upstream identities and forwarded headers.
-- Raw credentials participate in the digest but are not retained in the cache.
-- @param conf table Validated route configuration.
-- @param ctx table Request context including captured incoming headers.
-- @return string Hexadecimal SHA-256 routing fingerprint.
function routing.key(conf, ctx)
    local digest = sha256:new()
    digest:update(
        tostring(conf) .. ":" .. tostring(ctx.conf_version) .. ":" .. tostring(ctx.conf_id)
    )
    digest:update(json_canonical(conf))
    for _, server in ipairs(conf.servers) do
        local upstream_object = upstream_get_by_id(server.upstream_id)
        digest:update(tostring(upstream_object))
        if upstream_object then
            digest:update(tostring(upstream_object.resource_version))
        end
    end
    digest:update(json_canonical(headers_forward(ctx.mcp_headers)))
    return resty_string_to_hex(digest:final())
end


--- Publish ownership maps atomically to the worker-local bounded cache.
-- Preserves only unexpired unrelated kinds without extending their lifetimes.
-- Caps serialized ownership at 256 KiB per fingerprint (256 worker-local entries).
-- @param conf table Configuration containing routing_ttl.
-- @param key string Fingerprint computed before discovery.
-- @param result table Successful discovery result containing routing maps.
-- @return nil Mutates the worker-local cache only.
function routing.publish(conf, key, result)
    local old = cache:get(key) or {}
    local updated, now = {}, ngx_now()
    for kind, entry in pairs(old) do
        if entry.expires > now then
            updated[kind] = entry
        end
    end
    for kind, owners in pairs(result.routing) do
        updated[kind] = { owners = owners, expires = now + conf.routing_ttl }
    end
    local encoded = json_encode(updated)
    if not encoded or #encoded > 262144 then
        cache:delete(key)
        return
    end
    cache:set(key, updated, conf.routing_ttl)
end


--- Find a unique exposed owner in a routing snapshot.
-- Resource blocks apply globally, including across overlapping templates.
-- @param conf table Configuration containing resource filters.
-- @param snapshot table|nil Ownership maps from cache or fresh discovery.
-- @param kind string tools, prompts or resources.
-- @param name string Public name or concrete resource URI.
-- @return table|nil Owner record; nil for a miss, or nil and a denial string.
local function choose(conf, snapshot, kind, name)
    if not snapshot then
        return nil
    end
    if kind ~= "resources" then
        return snapshot[kind] and snapshot[kind][name]
    end
    if not snapshot.resources or not snapshot.templates then
        return nil
    end
    -- Explicit blocks apply globally so another overlapping template cannot bypass them.
    for _, server in ipairs(conf.servers) do
        for _, uri in ipairs(server.hidden_resource_uris or {}) do
            if uri == name then
                return nil, "Resource is hidden"
            end
        end
        for _, uri in ipairs(server.hidden_resource_templates or {}) do
            local pattern = template_compile(uri)
            if pattern and template_is_match(pattern, name) then
                return nil, "Resource is hidden"
            end
        end
    end
    local owner = snapshot.resources[name]
    for _, candidate in pairs(snapshot.templates) do
        if template_is_match(candidate.pattern, name) then
            if owner and owner.server ~= candidate.server then
                return nil, "Ambiguous resource owner"
            end
            owner = candidate
        end
    end
    return owner
end


--- Resolve an owner, discovering fresh catalogs on a cache miss.
-- Rejects configuration changes during discovery and never routes to a default.
-- @param conf table Validated route configuration.
-- @param ctx table APISIX request context.
-- @param kind string tools, prompts or resources.
-- @param name string Public name or concrete resource URI.
-- @return table|nil Owner; on failure nil, diagnostic string and HTTP failure metadata.
function routing.resolve(conf, ctx, kind, name)
    local key = routing.key(conf, ctx)
    local snapshot = {}
    for catalog, entry in pairs(cache:get(key) or {}) do
        if entry.expires > ngx_now() then
            snapshot[catalog] = entry.owners
        end
    end
    local owner, err = choose(conf, snapshot, kind, name)
    if err then
        return nil, err, { status = 400, code = -32602, message = err }
    end
    if owner then
        return owner
    end
    local wanted = kind == "resources" and { "resources", "templates" } or { kind }
    local result, why, detail = discovery_fetch(conf, ctx, wanted)
    if not result then
        return nil, why, detail
    end
    if key ~= routing.key(conf, ctx) then
        return nil,
            "Configuration changed during discovery",
            { status = 503, message = "Configuration changed during discovery" }
    end
    routing.publish(conf, key, result)
    owner, err = choose(conf, result.routing, kind, name)
    if not owner then
        local message = err or "No exposed owner for the requested object"
        return nil, message, { status = 400, code = -32602, message = message }
    end
    return owner
end
return routing
