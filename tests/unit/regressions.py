"""Exercise transport cleanup and cache isolation in real OpenResty with I/O doubles."""
import subprocess

LUA = r''' 
local original_ngx = ngx
local store, closes = {}, 0
local media = {"application/json", "application/json"}
local client = {
    set_timeouts = function() end,
    set_timeout = function() end,
    connect = function() return true end,
    request = function()
        return {status = 200, headers = {["Content-Type"] = media},
            body_reader = function() return nil end}
    end,
    close = function() closes = closes + 1; return true end,
}
package.loaded["resty.http"] = {new = function() return client end}
ngx = {now = function() return 100 end, sleep = function() error("slot leaked") end,
    log = function() end, WARN = 4, shared = {mcp_proxy_tickets = {
        safe_add = function(_, key, value)
            if store[key] then return nil end
            store[key] = value
            return true
        end,
        get = function(_, key) return store[key] end,
        delete = function(_, key) store[key] = nil end,
    }}}
local transport = require("apisix.plugins.mcp-proxy.transport")
local conf = {max_concurrency = 1, bridge_port = 9080, bridge_host = "internal",
    bridge_path = "/bridge", protocol_version = "2025-11-25", max_response_bytes = 4096,
    timeouts = {connect = 3, read_idle = 60}}
local ctx = {conf_id = "cleanup", mcp_headers = {}, var = {host = "public",
    remote_addr = "192.0.2.1", remote_port = "1234", scheme = "https", server_port = "443"}}
for i = 1, 3 do
    if i == 3 then media = nil end
    local value, err, detail = transport.request(conf, ctx,
        {upstream_id = "one", mcp_path = "/mcp"},
        {jsonrpc = "2.0", id = 1, method = "tools/call"}, 200)
    assert(value == nil and detail.status == 502, err)
    assert(detail.message == "Missing or repeated upstream Content-Type")
    assert(next(store) == nil, "ticket or concurrency slot leaked")
    assert(next(ctx.mcp_connections) == nil, "connection registry leaked")
    assert(closes == i, "socket not closed exactly once")
end
ngx = original_ngx
package.loaded["apisix.upstream"] = {get_by_id = function() return nil end}
local discoveries = 0
package.loaded["apisix.plugins.mcp-proxy.discovery"] = {fetch = function()
    discoveries = discoveries + 1
    return nil, "discovery marker", {status = 503}
end}
local routing = require("apisix.plugins.mcp-proxy.routing")
local cfg = {servers = {{upstream_id = "one"}}, routing_ttl = 30}
ctx.conf_version = 1
ctx.mcp_headers = {authorization = "Bearer same", host = "public"}
local key = routing.key(cfg, ctx)
routing.publish(cfg, key, {routing = {tools = {echo = {server = 1, original = "echo"}}}})
assert(routing.resolve(cfg, ctx, "tools", "echo").server == 1)
ctx.var.remote_port = "9999"
assert(routing.key(cfg, ctx) == key, "ephemeral ports should preserve cache reuse")
for field, value in pairs({remote_addr = "192.0.2.2", scheme = "http",
    host = "other", server_port = "80"}) do
    local old = ctx.var[field]
    ctx.var[field] = value
    assert(routing.key(cfg, ctx) ~= key, "context not isolated: " .. field)
    ctx.var[field] = old
end
-- A different address must miss the warmed ownership map and re-enter discovery.
ctx.var.remote_addr = "192.0.2.2"
ctx.mcp_deadline = ngx.now() - 1
local owner = routing.resolve(cfg, ctx, "tools", "echo")
assert(owner == nil and discoveries == 1, "different client reused cached ownership")
print("Transport cleanup and effective client-context isolation passed")
'''
subprocess.run([
    "docker", "compose", "exec", "-T", "gateway", "/usr/local/openresty/bin/resty",
    "-I", "/opt/mcp-proxy", "-e", LUA,
], check=True)
