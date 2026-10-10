-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Transport module.
-- @module apisix.plugins.mcp-proxy.transport
local require = require
local ngx = ngx
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local type = type

-- Calls travel through APISIX's own proxy/balancer, not directly to a node.
local http = require("resty.http")
local random = require("resty.random")
local resty_string = require("resty.string")
local json = require("apisix.plugins.mcp-proxy.json")
local headers = require("apisix.plugins.mcp-proxy.headers")
local sse = require("apisix.plugins.mcp-proxy.sse")

local headers_forward = headers.forward
local http_new = http.new
local json_decode = json.decode
local json_encode = json.encode
local json_is_object = json.is_object
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local ngx_log = ngx.log
local ngx_now = ngx.now
local ngx_sleep = ngx.sleep
local random_bytes = random.bytes
local sse_feed = sse.feed
local sse_new = sse.new
local resty_string_to_hex = resty_string.to_hex
local table_concat = table.concat

local transport = {}


--- Create a sanitized transport failure without leaking network details.
-- @param status integer HTTP status exposed by the gateway.
-- @param message string Public error description.
-- @param extra table|nil Allowed challenge or Retry-After headers.
-- @return string, table Diagnostic and HTTP failure metadata.
local function failure(status, message, extra)
    return message, { status = status, message = message, headers = extra }
end


--- Resolve a server timeout override with a route-default fallback.
-- @param conf table Configuration containing timeout defaults.
-- @param server table Upstream descriptor with optional timeouts.
-- @param key string Timeout field to resolve.
-- @return number Timeout in seconds.
local function budget(conf, server, key)
    return (server.timeouts and server.timeouts[key]) or conf.timeouts[key]
end


--- Send one JSON-RPC message through the same-instance APISIX bridge.
-- Acquires a shared concurrency slot and one-use ticket; closes sockets on all exits.
-- Uses one absolute deadline, bounds response bytes and never retries the request.
-- An emitter can commit response headers before a later transport error occurs.
-- @param conf table Validated configuration with transport limits.
-- @param ctx table Request context; tracks active connections for abort cleanup.
-- @param server table Upstream ID, MCP path and optional timeout overrides.
-- @param message table JSON-RPC request or notification.
-- @param deadline number Absolute ngx.now() deadline in seconds.
-- @param emit function|nil Callback(raw_json, is_stream): success, error string.
-- @return table|boolean|nil Reply or notification success; else nil, diagnostic, metadata.
function transport.request(conf, ctx, server, message, deadline, emit)
    local phase = "queue"


    --- Record bounded transport diagnostics without credentials or payloads.
    -- @param status integer Public HTTP failure status.
    -- @param reason string Sanitized failure category.
    -- @param extra table|nil Allowed public response headers.
    -- @return string, table Public diagnostic and HTTP failure metadata.
    local function request_failure(status, reason, extra)
        ngx_log(
            ngx.WARN,
            "MCP upstream failure: upstream_id=",
            server.upstream_id,
            " method=",
            message.method,
            " phase=",
            phase,
            " status=",
            status
        )
        return failure(status, reason, extra)
    end
    deadline = math_min(deadline, ctx.mcp_deadline or deadline)
    if ctx.mcp_discovery_failed then
        return nil, request_failure(502, "Aggregate discovery limit exceeded")
    end
    if ctx.mcp_aborted then
        return nil, request_failure(499, "Client disconnected")
    end
    local dict = ngx.shared.mcp_proxy_tickets
    if not dict then
        return nil, request_failure(503, "MCP transport is not configured")
    end
    local bytes = random_bytes(32, true)
    if not bytes then
        return nil, request_failure(503, "MCP transport unavailable")
    end
    local ticket = resty_string_to_hex(bytes)
    local route_id = tostring(ctx.conf_id or ctx.matched_route.value.id)
    local slot
    while ngx_now() < deadline and not slot and not ctx.mcp_aborted do
        for i = 1, conf.max_concurrency do
            local key = "slot:" .. route_id .. ":" .. i
            if dict:safe_add(key, ticket, math_max(1, deadline - ngx_now() + 1)) then
                slot = key
                break
            end
        end
        if not slot then
            ngx_sleep(0.01)
        end
    end
    if not slot then
        return nil, request_failure(504, "Upstream concurrency budget exhausted")
    end


    --- Release the captured concurrency slot only if this ticket still owns it.
    -- @return nil Mutates the shared ticket dictionary; safe to call repeatedly.
    local function release()
        if dict:get(slot) == ticket then
            dict:delete(slot)
        end
    end
    local record = {
        upstream_id = server.upstream_id,
        host = ctx.var.http_host or ctx.var.host,
        path = server.mcp_path,
        client_ip = ctx.var.remote_addr,
        client_port = tonumber(ctx.var.remote_port),
        forwarded_for = ctx.mcp_headers["x-forwarded-for"],
        forwarded_proto = ctx.mcp_headers["x-forwarded-proto"] or ctx.var.scheme,
        forwarded_host = ctx.mcp_headers["x-forwarded-host"] or ctx.var.host,
        forwarded_port = ctx.mcp_headers["x-forwarded-port"] or ctx.var.server_port,
        timeout = {
            connect = budget(conf, server, "connect"),
            read = budget(conf, server, "read_idle"),
            send = budget(conf, server, "read_idle"),
        },
    }
    local encoded_record = json_encode(record)
    if not encoded_record then
        release()
        return nil, request_failure(502, "Invalid internal transport context")
    end
    local ok = dict:safe_add(ticket, encoded_record, math_max(1, deadline - ngx_now()))
    if not ok then
        release()
        return nil, request_failure(503, "MCP transport capacity exhausted")
    end
    local body = json_encode(message)
    if not body then
        release()
        dict:delete(ticket)
        return nil, request_failure(502, "Unable to encode upstream request")
    end
    local client = http_new()
    local remaining = math_max(1, math_floor((deadline - ngx_now()) * 1000))
    client:set_timeouts(
        math_min(remaining, budget(conf, server, "connect") * 1000),
        remaining,
        math_min(remaining, budget(conf, server, "read_idle") * 1000)
    )
    phase = "connect"
    local connected, connect_err =
        client:connect({ scheme = "http", host = "127.0.0.1", port = conf.bridge_port })
    if not connected then
        release()
        dict:delete(ticket)
        return nil,
            request_failure(connect_err == "timeout" and 504 or 502, "MCP transport unavailable")
    end
    ctx.mcp_connections = ctx.mcp_connections or {}


    --- Release the captured slot, ticket and client socket.
    -- Also removes this client from the request abort-cleanup registry.
    -- @return nil Cleanup is idempotent from the caller perspective.
    local function close()
        release()
        dict:delete(ticket)
        ctx.mcp_connections[client] = nil
        -- Abort and normal completion can both reach cleanup.
        local closed, close_err = client:close()
        if not closed and close_err ~= "closed" then
            ngx_log(ngx.WARN, "MCP socket cleanup failed")
        end
    end
    ctx.mcp_connections[client] = close
    local forwarded = headers_forward(ctx.mcp_headers)
    -- Use a dedicated routing host; the ticket carries the public upstream Host.
    forwarded.host = conf.bridge_host
    forwarded["x-mcp-proxy-ticket"] = ticket
    forwarded["content-type"] = "application/json"
    forwarded.accept = "application/json, text/event-stream"
    forwarded["mcp-protocol-version"] = conf.protocol_version
    -- Never let caller-supplied forwarding headers acquire trust on loopback.
    forwarded["x-forwarded-for"] = record.forwarded_for
    forwarded["x-real-ip"] = record.client_ip
    forwarded.forwarded = nil
    local request_left = deadline - ngx_now()
    if request_left <= 0 then
        close()
        return nil, request_failure(504, "Upstream total deadline exceeded")
    end
    client:set_timeout(math_min(request_left, budget(conf, server, "read_idle")) * 1000)
    phase = "headers"
    local response, err = client:request({
        method = "POST",
        path = conf.bridge_path,
        headers = forwarded,
        body = body,
    })
    if not response then
        close()
        return nil, request_failure(err == "timeout" and 504 or 502, "Upstream transport failed")
    end
    if response.status < 200 or response.status >= 300 then
        local status = response.status
        local extra = {}
        if status == 401 or status == 403 then
            extra["WWW-Authenticate"] = response.headers["WWW-Authenticate"]

        elseif status == 429 then
            extra["Retry-After"] = response.headers["Retry-After"]

        elseif status ~= 504 then
            status = 502
        end
        close()
        return nil, request_failure(status, "Upstream HTTP request failed", extra)
    end
    if response.headers["Mcp-Session-Id"] then
        close()
        return nil,
            request_failure(502, "Upstream requires sessions; stateless profile is incompatible")
    end
    local encoding = response.headers["Content-Encoding"]
    if encoding and encoding ~= "identity" then
        close()
        return nil, request_failure(502, "Compressed upstream responses are unsupported")
    end
    if message.id == nil and response.status == 202 then
        close()
        return true
    end
    local media = (response.headers["Content-Type"] or ""):lower():match("^%s*([^;%s]+)")
    if media ~= "application/json" and media ~= "text/event-stream" then
        close()
        return nil, request_failure(502, "Unexpected upstream response media type")
    end
    local chunks, total, result = {}, 0, nil
    local parser = sse_new(conf.max_response_bytes)


    --- Validate response correlation and optionally forward an upstream event.
    -- Captures the single final result; only progress notifications are forwarded.
    -- @param msg table Decoded JSON-RPC event.
    -- @param raw string Original event JSON, preserved when forwarding.
    -- @return boolean|nil True when accepted; nil and a diagnostic string otherwise.
    local function event(msg, raw)
        if not json_is_object(msg) or msg.jsonrpc ~= "2.0" then
            return nil, "Invalid upstream JSON-RPC"
        end
        if msg.method then
            if msg.id ~= nil then
                return nil, "Unsupported server-initiated request"
            end
            if msg.method == "notifications/progress" and emit then
                return emit(raw, true)
            end
            return true
        end
        if msg.id ~= message.id or (msg.result == nil) == (msg.error == nil) or result then
            return nil, "Invalid upstream response correlation"
        end
        result = msg
        if emit then
            return emit(raw, media == "text/event-stream")
        end
        return true
    end
    phase = "body"
    while true do
        local left = deadline - ngx_now()
        if left <= 0 then
            close()
            return nil, request_failure(504, "Upstream total deadline exceeded")
        end
        client:set_timeout(math_min(left, budget(conf, server, "read_idle")) * 1000)
        -- For SSE with Content-Length, a larger read can wait for the final
        -- result before exposing a short progress event. Lua cosockets buffer
        -- network reads; single-byte framing preserves prompt event delivery.
        local chunk, read_err = response.body_reader(media == "text/event-stream" and 1 or 8192)
        if read_err then
            close()
            return nil,
                request_failure(
                    read_err == "timeout" and 504 or 502,
                    "Upstream response interrupted"
                )
        end
        if not chunk then
            break
        end
        if ctx.mcp_discovering then
            -- Cooperative light threads cannot interleave this non-yielding debit.
            ctx.mcp_discovery_bytes = (ctx.mcp_discovery_bytes or 0) + #chunk
            if ctx.mcp_discovery_bytes > conf.max_discovery_bytes then
                ctx.mcp_discovery_failed = true
                close()
                return nil, request_failure(502, "Aggregate discovery byte limit exceeded")
            end
        end
        total = total + #chunk
        if total > conf.max_response_bytes then
            close()
            return nil, request_failure(502, "Upstream response exceeds configured limit")
        end
        if media == "text/event-stream" then
            local valid, why = sse_feed(parser, chunk, event)
            if not valid then
                close()
                return nil, request_failure(502, why)
            end
            if result then
                break
            end

        else
            chunks[#chunks + 1] = chunk
        end
    end
    if media == "application/json" then
        local raw = table_concat(chunks)
        local msg = json_decode(raw)
        if not msg then
            close()
            return nil, request_failure(502, "Malformed upstream JSON")
        end
        local valid, why = event(msg, raw)
        if not valid then
            close()
            return nil, request_failure(502, why)
        end
    end
    close()
    if not result then
        return nil, request_failure(502, "Upstream stream ended without a result")
    end
    return result
end


--- Negotiate the configured stateless revision and acknowledge initialization.
-- Checks server identity/capabilities; both messages share the caller deadline.
-- @param conf table Validated configuration with protocol_version.
-- @param ctx table APISIX request context.
-- @param server table Upstream descriptor.
-- @param deadline number Absolute ngx.now() deadline in seconds.
-- @return table|nil Initialization result; else nil, diagnostic and HTTP failure metadata.
function transport.initialize(conf, ctx, server, deadline)
    local result, err, detail = transport.request(conf, ctx, server, {
        jsonrpc = "2.0",
        id = "proxy-init",
        method = "initialize",
        params = {
            protocolVersion = conf.protocol_version,
            capabilities = {},
            clientInfo = { name = "apisix-mcp-proxy", version = "0.1.1" },
        },
    }, deadline)
    if not result then
        return nil, err, detail
    end
    local init = result.result
    if
        not json_is_object(init)
        or init.protocolVersion ~= conf.protocol_version
        or not json_is_object(init.capabilities)
        or not json_is_object(init.serverInfo)
    then
        return nil, failure(502, "Incompatible upstream initialization")
    end
    if
        type(init.serverInfo.name) ~= "string"
        or type(init.serverInfo.version) ~= "string"
        or (init.instructions ~= nil and type(init.instructions) ~= "string")
    then
        return nil, failure(502, "Malformed upstream identity or instructions")
    end
    for _, name in ipairs({ "tools", "prompts", "resources" }) do
        if init.capabilities[name] ~= nil and not json_is_object(init.capabilities[name]) then
            return nil, failure(502, "Malformed upstream capability")
        end
    end
    local notified, why, notify_detail = transport.request(
        conf,
        ctx,
        server,
        { jsonrpc = "2.0", method = "notifications/initialized" },
        deadline
    )
    if not notified then
        return nil, why, notify_detail
    end
    return init
end
return transport
