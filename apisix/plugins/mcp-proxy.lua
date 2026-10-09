-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Mcp proxy module.
-- @module apisix.plugins.mcp-proxy
local require = require
local ngx = ngx
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type

local MAX_SAFE_INTEGER = 9007199254740991
local core = require("apisix.core")
local json = require("apisix.plugins.mcp-proxy.json")
local auth = require("apisix.plugins.mcp-proxy.auth")
local template = require("apisix.plugins.mcp-proxy.template")
local discovery = require("apisix.plugins.mcp-proxy.discovery")
local routing = require("apisix.plugins.mcp-proxy.routing")
local transport = require("apisix.plugins.mcp-proxy.transport")
local apisix_client = require("resty.apisix.client")

local apisix_client_set_real_ip = apisix_client.set_real_ip
local auth_challenge = auth.challenge
local auth_metadata = auth.metadata
local core_log_error = core.log.error
local core_log_warn = core.log.warn
local core_request_header = core.request.header
local core_request_get_body = core.request.get_body
local core_response_exit = core.response.exit
local core_schema_check = core.schema.check
local core_table_clone = core.table.clone
local discovery_fetch = discovery.fetch
local discovery_parallel = discovery.parallel
local json_array = json.array
local json_decode = json.decode
local json_encode = json.encode
local json_is_object = json.is_object
local math_abs = math.abs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local ngx_exit = ngx.exit
local ngx_flush = ngx.flush
local ngx_now = ngx.now
local ngx_on_abort = ngx.on_abort
local ngx_print = ngx.print
local ngx_req_clear_header = ngx.req.clear_header
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_method = ngx.req.get_method
local ngx_req_set_header = ngx.req.set_header
local routing_key = routing.key
local routing_publish = routing.publish
local routing_resolve = routing.resolve
local table_concat = table.concat
local table_sort = table.sort
local template_compile = template.compile
local transport_initialize = transport.initialize
local transport_request = transport.request


--- Build an inclusive integer schema with a default.
-- @param default integer Default value applied by schema validation.
-- @param minimum integer Smallest accepted value.
-- @param maximum integer Largest accepted value.
-- @return table Integer schema definition.
local function bounded(default, minimum, maximum)
    return { type = "integer", default = default, minimum = minimum, maximum = maximum }
end
local strings = { type = "array", items = { type = "string" }, maxItems = 4096 }
-- APISIX's schema compiler has no portable cjson-null branch. Validate map
-- values explicitly below, keeping null distinct from a missing Lua key.
local aliases = { type = "object", additionalProperties = {} }
local timeouts = {
    type = "object",
    additionalProperties = false,
    properties = {
        connect = bounded(3, 1, 30),
        discovery_total = bounded(10, 1, 120),
        read_idle = bounded(60, 1, 300),
        operation_total = bounded(120, 1, 600),
        request_total = bounded(120, 1, 600),
    },
}
-- Per-server limits can narrow individual phases, not redefine the public deadline.
local server_timeouts = core_table_clone(timeouts)
server_timeouts.properties = core_table_clone(timeouts.properties)
server_timeouts.properties.request_total = nil
local schema = {
    type = "object",
    additionalProperties = false,
    properties = {
        mode = { type = "string", enum = { "proxy", "metadata", "bridge" }, default = "proxy" },
        server_info = {
            type = "object",
            required = { "name", "version" },
            properties = {
                name = { type = "string", minLength = 1 },
                version = {
                    type = "string",
                    minLength = 1,
                },
            },
        },
        instructions = { type = "string", maxLength = 65536, default = "" },
        protocol_version = { type = "string", enum = { "2025-11-25" }, default = "2025-11-25" },
        auth_metadata = {
            type = "object",
            additionalProperties = false,
            required = { "resource", "metadata_url", "authorization_servers" },
            properties = {
                resource = { type = "string", pattern = "^https://[^#?]+$" },
                metadata_url = { type = "string", pattern = "^https://[^#?]+$" },
                authorization_servers = {
                    type = "array",
                    minItems = 1,
                    items = { type = "string", pattern = "^https://" },
                },
                scopes_supported = strings,
            },
        },
        servers = {
            type = "array",
            minItems = 1,
            maxItems = 64,
            items = {
                type = "object",
                additionalProperties = false,
                required = { "upstream_id", "mcp_path" },
                properties = {
                    upstream_id = {
                        anyOf = { { type = "string", minLength = 1 }, { type = "integer" } },
                    },
                    mcp_path = { type = "string", pattern = "^/[^?#\r\n]*$" },
                    tool_aliases = aliases,
                    prompt_aliases = aliases,
                    hidden_resource_uris = strings,
                    hidden_resource_templates = strings,
                    timeouts = server_timeouts,
                },
            },
        },
        timeouts = timeouts,
        max_concurrency = bounded(16, 1, 64),
        max_pages = bounded(64, 1, 1024),
        max_entries = bounded(4096, 1, 16384),
        max_response_bytes = bounded(4194304, 1024, 33554432),
        max_discovery_bytes = bounded(16777216, 1024, 67108864),
        max_discovery_entries = bounded(16384, 1, 65536),
        max_request_bytes = bounded(1048576, 1024, 8388608),
        routing_ttl = bounded(30, 1, 300),
        bridge_port = bounded(9080, 1, 65535),
        bridge_host = {
            type = "string",
            default = "mcp-proxy.internal.invalid",
            pattern = "^[a-zA-Z0-9][a-zA-Z0-9.-]*$",
            maxLength = 253,
        },
        bridge_path = {
            type = "string",
            default = "/_mcp_proxy_internal",
            pattern = "^/[a-zA-Z0-9/_-]+$",
        },
        allowed_origins = strings,
    },
}
local mcp_proxy = { version = 0.1, priority = -500, name = "mcp-proxy", schema = schema }


--- Validate route configuration and normalize explicit YAML alias nulls.
-- Mutates alias values in conf; never treats an ordinary empty table as null.
-- @param conf table Plugin configuration supplied by APISIX.
-- @return boolean valid; on failure, followed by a diagnostic string.
function mcp_proxy.check_schema(conf)
    -- Standalone YAML uses lyaml.null (a table), whereas Admin API JSON uses
    -- cjson.null. Normalize the library's exact sentinel, never arbitrary {}.
    if type(conf) ~= "table" then
        return false, "Plugin configuration must be an object"
    end
    local yaml_ok, yaml = pcall(require, "lyaml")
    for _, server in ipairs(type(conf.servers) == "table" and conf.servers or {}) do
        if type(server) ~= "table" then
            return false, "Each server must be an object"
        end
        for _, field in ipairs({ "tool_aliases", "prompt_aliases" }) do
            if type(server[field]) == "table" then
                for name, value in pairs(server[field]) do
                    if yaml_ok and value == yaml.null then
                        server[field][name] = json.null
                    end
                end
            end
        end
    end
    local ok, err = core_schema_check(schema, conf)
    if not ok then
        return false, err
    end
    if conf.mode == "bridge" then
        return true
    end
    if not conf.auth_metadata then
        return false, "auth_metadata is required"
    end
    local metadata_config = conf.auth_metadata
    local origin, path = metadata_config.resource:match("^(https://[^/]+)(/.*)$")
    if
        not origin
        or metadata_config.metadata_url
            ~= origin .. "/.well-known/oauth-protected-resource" .. path
    then
        return false, "metadata_url must be the RFC 9728 path-based URL for resource"
    end
    if conf.mode == "metadata" then
        return true
    end
    if not conf.servers or not conf.server_info then
        return false, "servers and server_info are required"
    end
    for _, server in ipairs(conf.servers) do
        for _, field in ipairs({ "tool_aliases", "prompt_aliases" }) do
            local used = {}
            for _, alias in pairs(server[field] or {}) do
                if alias ~= ngx.null and alias ~= json.null then
                    if type(alias) ~= "string" or #alias < 1 or #alias > 128 then
                        return false,
                            "Alias must be a nonempty string or JSON null (got "
                                .. type(alias)
                                .. ")"
                    end
                    if used[alias] then
                        return false, "Duplicate public alias in " .. field
                    end
                    used[alias] = true
                end
            end
        end
        for _, uri in ipairs(server.hidden_resource_templates or {}) do
            local pattern, why = template_compile(uri)
            if not pattern then
                return false, why
            end
        end
    end
    return true
end


--- Populate missing timeout defaults in the validated configuration.
-- Mutates conf.timeouts; preserves explicit per-route values.
-- @param conf table Validated plugin configuration.
-- @return nil
local function defaults(conf)
    if not conf.timeouts then
        conf.timeouts = {}
    end
    for key, value in pairs({
        connect = 3,
        discovery_total = 10,
        read_idle = 60,
        operation_total = 120,
        request_total = 120,
    }) do
        if not conf.timeouts[key] then
            conf.timeouts[key] = value
        end
    end
end


--- Serialize a JSON response and terminate the current APISIX request.
-- Sets Content-Type and delegates termination to core.response.exit.
-- @param status integer HTTP response status.
-- @param value table JSON response payload.
-- @return nil Does not return during normal request processing.
local function reply(status, value)
    local body, err = json_encode(value)
    if not body then
        core_log_error("MCP response serialization failed: ", err)
        return core_response_exit(500)
    end
    local ctx = ngx.ctx.api_ctx
    if ctx and ctx.mcp_response_limit and #body > ctx.mcp_response_limit then
        status = 502
        body = json_encode({
            jsonrpc = "2.0",
            id = value.id or json.null,
            error = { code = -32002, message = "Public response exceeds configured limit" },
        })
    end
    ngx.header["Content-Type"] = "application/json"
    return core_response_exit(status, body)
end


--- Send a sanitized JSON-RPC error and any allowed authentication headers.
-- @param id string|number|nil Request ID, or nil to emit JSON null.
-- @param err table Failure metadata: status, code, message and optional headers.
-- @return nil Terminates the request through reply.
local function fail(id, err)
    for name, value in pairs(err.headers or {}) do
        ngx.header[name] = value
    end
    return reply(err.status or 502, {
        jsonrpc = "2.0",
        id = id or json.null,
        error = { code = err.code or -32002, message = err.message or "MCP gateway failure" },
    })
end


--- Consume a one-use bridge ticket and restore verified client addressing.
-- Only the loopback bridge route is handled; mutates ctx and request headers.
-- @param conf table Validated plugin configuration.
-- @param ctx table APISIX request context.
-- @return integer|nil HTTP rejection status, or nil to continue the phase.
function mcp_proxy.rewrite(conf, ctx)
    -- All normal authentication/policy plugins must run before this plugin.
    if conf.mode ~= "bridge" then
        return
    end
    local peer = ngx.var.realip_remote_addr or ngx.var.remote_addr
    if peer ~= "127.0.0.1" and peer ~= "::1" then
        return 404
    end
    local ticket = core_request_header(ctx, "x-mcp-proxy-ticket")
    local dict = ngx.shared.mcp_proxy_tickets
    if type(ticket) ~= "string" or not ticket:match("^[a-f0-9]+$") or #ticket ~= 64 or not dict then
        return 404
    end
    local raw = dict:get(ticket)
    if not raw or not dict:safe_add("used:" .. ticket, true, math_max(1, dict:ttl(ticket) + 1)) then
        return 404
    end
    dict:delete(ticket)
    local record = json_decode(raw)
    if not record then
        return 404
    end
    -- Routing has completed. Restore the public Host only after ticket validation;
    -- APISIX still applies the selected upstream's pass/rewrite/node policy.
    ngx_req_set_header("Host", record.host)
    ctx.var.http_host = nil
    ctx.var.host = nil
    ctx.var.upstream_host = record.host
    ctx.mcp_bridge = record
    ngx_req_clear_header("x-mcp-proxy-ticket")
    local changed = apisix_client_set_real_ip(record.client_ip, record.client_port)
    if not changed then
        return 503
    end
    ctx.var.remote_addr = nil
    ctx.var.remote_port = nil
    ctx.var.realip_remote_addr = nil
    ctx.var.realip_remote_port = nil
end


--- Apply request-local bridge routing, timeouts and TLS identity.
-- Clones upstream configuration to disable retries without changing shared state.
-- Resolved certificate material makes native connection pools respect rotation.
-- @param conf table Validated plugin configuration.
-- @param ctx table APISIX context containing the consumed bridge ticket.
-- @return nil Mutates ctx.upstream_conf, upstream URI and forwarding headers.
local function prepare_bridge(conf, ctx)
    if conf.mode ~= "bridge" or not ctx.mcp_bridge then
        return
    end
    local copy = core_table_clone(ctx.upstream_conf)
    copy.retries = 0
    copy.timeout = ctx.mcp_bridge.timeout
    if copy.tls and copy.tls.client_cert_id and ctx.upstream_ssl then
        -- APISIX 3.19 resolves the current SSL object before this hook, but its
        -- pool key otherwise includes only the immutable client_cert_id. Use
        -- the resolved PEM on this request's copy so rotation changes the
        -- native pool identity as well as the handshake certificate.
        copy.tls = core_table_clone(copy.tls)
        copy.tls.client_cert = ctx.upstream_ssl.cert
        copy.tls.client_key = ctx.upstream_ssl.key
        copy.tls.client_cert_id = nil
    end
    ctx.upstream_conf = copy
    ctx.var.upstream_uri = ctx.mcp_bridge.path
    ngx_req_set_header("X-Forwarded-For", ctx.mcp_bridge.forwarded_for)
    ngx_req_set_header("X-Forwarded-Proto", ctx.mcp_bridge.forwarded_proto)
    ngx_req_set_header("X-Forwarded-Host", ctx.mcp_bridge.forwarded_host)
    ngx_req_set_header("X-Forwarded-Port", ctx.mcp_bridge.forwarded_port)
end


--- Decorate auth challenges with public metadata and remove session headers.
-- @param conf table Validated plugin configuration.
-- @param _ctx table APISIX request context; unused by this hook.
-- @return nil Mutates response headers.
function mcp_proxy.header_filter(conf, _ctx)
    if conf.mode == "bridge" or not conf.auth_metadata then
        return
    end
    if ngx.status == 401 or ngx.status == 403 then
        local value =
            auth_challenge(ngx.header["WWW-Authenticate"], conf.auth_metadata.metadata_url)
        if value then
            ngx.header["WWW-Authenticate"] = value
        end
    end
    ngx.header["Mcp-Session-Id"] = nil
end


--- Negotiate capabilities and assemble the public server identity.
-- @param conf table Validated route configuration.
-- @param ctx table Authenticated APISIX request context.
-- @param message table Validated initialize request with a non-null ID.
-- @return nil Sends a JSON-RPC result or terminates with an upstream failure.
local function handle_initialize(conf, ctx, message)
    local id = message.id
    local params = message.params or {}
    if
        type(params.protocolVersion) ~= "string"
        or not json_is_object(params.capabilities)
        or not json_is_object(params.clientInfo)
    then
        return fail(id, { status = 400, code = -32602, message = "Invalid initialize parameters" })
    end


    --- Initialize one server using its discovery timeout override.
    -- @param server table Configured upstream descriptor.
    -- @return table|nil Initialization result; else nil, diagnostic, metadata.
    local function initialize_server(server)
        local timeout = (server.timeouts or {}).discovery_total or conf.timeouts.discovery_total
        return transport_initialize(
            conf,
            ctx,
            server,
            math_min(ctx.mcp_deadline, ngx_now() + timeout)
        )
    end
    ctx.mcp_discovering = true
    local results, err, detail = discovery_parallel(conf, initialize_server)
    ctx.mcp_discovering = false
    if not results then
        return fail(id, detail or { message = err })
    end
    local capabilities, instructions = {}, { conf.instructions }
    for i, result in ipairs(results) do
        for _, kind in ipairs({ "tools", "prompts", "resources" }) do
            if result.capabilities[kind] then
                capabilities[kind] = {}
            end
        end
        if result.instructions then
            instructions[#instructions + 1] = "\nUpstream " .. i .. ":\n" .. result.instructions
        end
        for _, field in ipairs({ "tool_aliases", "prompt_aliases" }) do
            local mappings = {}
            for original, alias in pairs(conf.servers[i][field] or {}) do
                if type(alias) == "string" then
                    mappings[#mappings + 1] = original .. " -> " .. alias
                end
            end
            table_sort(mappings)
            if #mappings > 0 then
                instructions[#instructions + 1] = field .. ": " .. table_concat(mappings, ", ")
            end
        end
    end
    return reply(200, {
        jsonrpc = "2.0",
        id = id,
        result = {
            protocolVersion = conf.protocol_version,
            serverInfo = conf.server_info,
            capabilities = capabilities,
            instructions = table_concat(instructions, "\n"),
        },
    })
end


--- Discover one public catalog and publish its ownership snapshot.
-- @param conf table Validated route configuration.
-- @param ctx table Authenticated APISIX request context.
-- @param message table Validated catalog request with a non-null ID.
-- @param kind string Catalog kind used by discovery and routing.
-- @param spec table Protocol field names for this catalog kind.
-- @return nil Sends the complete catalog or terminates with a failure.
local function handle_catalog(conf, ctx, message, kind, spec)
    local id = message.id
    if message.params and message.params.cursor ~= nil then
        return fail(id, {
            status = 400,
            code = -32602,
            message = "Public catalog cursors are unsupported",
        })
    end
    local key = routing_key(conf, ctx)
    local result, err, detail = discovery_fetch(conf, ctx, { kind })
    if not result then
        return fail(id, detail or { message = err })
    end
    local envelope = { jsonrpc = "2.0", id = id, result = { [spec.field] = result.catalogs[kind] } }
    local encoded_catalog = json_encode(envelope)
    if not encoded_catalog or #encoded_catalog > conf.max_response_bytes then
        return fail(id, { status = 502, message = "Merged catalog exceeds response bound" })
    end
    if key ~= routing_key(conf, ctx) then
        return fail(id, { status = 503, message = "Configuration changed during discovery" })
    end
    routing_publish(conf, key, result)
    return reply(200, envelope)
end


--- Delegate one operation to its owner and relay the response without retries.
-- @param conf table Validated route configuration.
-- @param ctx table Request context with abort cleanup already registered.
-- @param message table Validated JSON-RPC request with a non-null ID.
-- @return nil Sends JSON or SSE and terminates the current request.
local function handle_operation(conf, ctx, message)
    local method, id = message.method, message.id
    local operations = {
        ["tools/call"] = { "tools", "name" },
        ["prompts/get"] = { "prompts", "name" },
        ["resources/read"] = { "resources", "uri" },
    }
    local operation = operations[method]
    if not operation then
        return fail(
            id,
            { status = 400, code = -32601, message = "Method is outside the supported MCP profile" }
        )
    end
    local params = message.params or {}
    if type(params[operation[2]]) ~= "string" or params.task ~= nil then
        return fail(
            id,
            { status = 400, code = -32602, message = "Invalid or unsupported operation parameters" }
        )
    end
    local owner, err, detail = routing_resolve(conf, ctx, operation[1], params[operation[2]])
    if not owner then
        return fail(id, detail or { message = err })
    end
    local server = conf.servers[owner.server]
    local deadline = math_min(
        ctx.mcp_deadline,
        ngx_now() + ((server.timeouts or {}).operation_total or conf.timeouts.operation_total)
    )
    local init, why, init_detail = transport_initialize(conf, ctx, server, deadline)
    if not init then
        return fail(id, init_detail or { message = why })
    end
    if operation[1] ~= "resources" then
        params[operation[2]] = owner.original
    end
    local sent = false


    --- Forward response bytes and flush complete progress events immediately.
    -- @param body string Original validated upstream JSON.
    -- @param stream boolean Whether to frame the bytes as an SSE message.
    -- @return boolean|nil Flush success, or nil and a client I/O diagnostic.
    local function emit_response(body, stream)
        if not sent then
            ngx.status = 200
            ngx.header["Content-Type"] = stream and "text/event-stream" or "application/json"
            ngx.header["Cache-Control"] = "no-store"
            sent = true
        end
        local ok = ngx_print(
            stream and "event: message\ndata: " .. body:gsub("\n", "\ndata: ") .. "\n\n" or body
        )
        if not ok then
            return nil, "Client disconnected"
        end
        return ngx_flush(true)
    end
    local result, issue, request_detail =
        transport_request(conf, ctx, server, message, deadline, emit_response)
    if not result then
        if not sent then
            return fail(id, request_detail or { message = issue })
        end
        -- After SSE headers/progress, finish with a correlated protocol error.
        ngx_print("event: message\ndata: " .. json_encode({
            jsonrpc = "2.0",
            id = id,
            error = { code = -32002, message = issue },
        }) .. "\n\n")
    end
    return ngx_exit(200)
end


--- Serve metadata or dispatch a stateless MCP request after authentication.
-- Validates input, discovers catalogs and routes operations without retrying writes.
-- Registers abort cleanup; streamed responses may commit headers before completion.
-- @param conf table Validated plugin configuration.
-- @param ctx table APISIX context shared with auth and upstream phases.
-- @return integer|nil Phase rejection status, or terminates through the response API.
local function dispatch(conf, ctx)
    if conf.mode == "metadata" then
        if ngx_req_get_method() ~= "GET" then
            ngx.header.Allow = "GET"
            return 405
        end
        local meta = auth_metadata(conf)
        meta.bearer_methods_supported = json_array(meta.bearer_methods_supported)
        return reply(200, meta)
    end
    defaults(conf)
    local incoming, truncated = ngx_req_get_headers(256)
    if truncated then
        return fail(nil, { status = 431, message = "Too many request headers" })
    end
    ctx.mcp_headers = incoming
    local origin = incoming.origin
    if origin then
        local allowed = false
        for _, value in ipairs(conf.allowed_origins or {}) do
            if origin == value then
                allowed = true
            end
        end
        if not allowed then
            return fail(nil, { status = 403, message = "Origin is not allowed" })
        end
    end
    if ngx_req_get_method() ~= "POST" then
        ngx.header.Allow = "POST"
        return 405
    end
    if incoming["mcp-session-id"] then
        return fail(nil, { status = 400, message = "This endpoint uses a stateless MCP profile" })
    end
    if incoming["content-encoding"] and incoming["content-encoding"] ~= "identity" then
        return fail(nil, { status = 415, message = "Compressed request bodies are unsupported" })
    end
    if
        type(incoming["content-type"]) ~= "string"
        or incoming["content-type"]:lower():match("^%s*([^;%s]+)") ~= "application/json"
    then
        return fail(nil, { status = 415, message = "Expected application/json" })
    end
    local raw, body_err = core_request_get_body(conf.max_request_bytes, ctx)
    if not raw then
        local status = 400
        if body_err then
            status = body_err:find("maximum size", 1, true) and 413 or 500
        end
        return fail(nil, { status = status, message = "Request body unavailable or too large" })
    end
    if #raw > conf.max_request_bytes then
        return fail(nil, { status = 413, message = "Request body exceeds configured limit" })
    end
    local message = json_decode(raw)
    if not message then
        return fail(nil, { status = 400, code = -32700, message = "Invalid JSON" })
    end
    if
        not json_is_object(message)
        or message.jsonrpc ~= "2.0"
        or type(message.method) ~= "string"
        or (message.id ~= nil and type(message.id) ~= "string" and type(message.id) ~= "number")
        or (message.params ~= nil and not json_is_object(message.params))
    then
        return fail(nil, { status = 400, code = -32600, message = "Invalid JSON-RPC request" })
    end
    local method, id = message.method, message.id
    if type(id) == "number" and (id ~= math_floor(id) or math_abs(id) > MAX_SAFE_INTEGER) then
        return fail(nil, {
            status = 400,
            code = -32600,
            message = "Use a string ID or a safe integer JSON-RPC ID",
        })
    end
    -- A valid authenticated discovery probe may negotiate by falling back to
    -- initialize. This negative response does not implement a newer revision.
    if method == "server/discover" and id ~= nil then
        return fail(id, { status = 404, code = -32601, message = "Method not found" })
    end
    if method ~= "initialize" and incoming["mcp-protocol-version"] ~= conf.protocol_version then
        return fail(
            id,
            { status = 400, code = -32602, message = "Unsupported or missing MCP-Protocol-Version" }
        )
    end
    if id == nil then
        -- Stateless profile has no persistent stream or cancellable session registry.
        if method:match("^notifications/") then
            return core_response_exit(202)
        end
        return fail(nil, { status = 400, code = -32600, message = "Request ID is required" })
    end


    --- Close active upstream sockets when the downstream client disconnects.
    -- @return nil Marks the request aborted and invokes registered cleanup.
    local function abort_request()
        ctx.mcp_aborted = true
        for _, close in pairs(ctx.mcp_connections or {}) do
            -- Continue cleaning other sockets even if one cleanup raises.
            local ok = pcall(close)
            if not ok then
                core_log_warn("MCP connection cleanup failed")
            end
        end
    end
    local abort_ok = ngx_on_abort(abort_request)
    if not abort_ok then
        return fail(id, { status = 503, message = "Client abort handling is unavailable" })
    end
    if method == "ping" then
        return reply(200, { jsonrpc = "2.0", id = id, result = {} })
    end
    if method == "initialize" then
        return handle_initialize(conf, ctx, message)
    end
    for kind, spec in pairs(discovery.kinds) do
        if method == spec.method then
            return handle_catalog(conf, ctx, message, kind, spec)
        end
    end
    return handle_operation(conf, ctx, message)
end


--- Defer public responses until all access policies have run.
-- Bridge requests still use native APISIX upstream selection.
-- @param conf table Validated plugin configuration.
-- @param ctx table Request context shared with subsequent plugins.
-- @return integer|nil Rejection status for an invalid bridge ticket.
function mcp_proxy.access(conf, ctx)
    if conf.mode == "bridge" then
        if not ctx.mcp_bridge then
            return 404
        end
        ctx.upstream_id = ctx.mcp_bridge.upstream_id
        return
    end
    defaults(conf)
    ctx.mcp_deadline = ngx_now() + conf.timeouts.request_total
    ctx.mcp_response_limit = conf.max_response_bytes
    ctx.bypass_nginx_upstream = true
end


--- Execute public MCP only after access, or prepare the native bridge.
-- before_proxy policies must have a higher priority than this response producer.
-- @param conf table Validated plugin configuration.
-- @param ctx table Request context after access policies have completed.
-- @return integer|nil Rejection status or response termination.
function mcp_proxy.before_proxy(conf, ctx)
    if conf.mode == "bridge" then
        return prepare_bridge(conf, ctx)
    end
    if ctx.mcp_deadline then
        return dispatch(conf, ctx)
    end
end
return mcp_proxy
