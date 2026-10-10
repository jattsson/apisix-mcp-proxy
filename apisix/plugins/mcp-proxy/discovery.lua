-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 jattsson and contributors


--- Discovery module.
-- @module apisix.plugins.mcp-proxy.discovery
local require = require
local ngx = ngx
local ipairs = ipairs
local pcall = pcall
local type = type

local table_new = require("table.new")
local json = require("apisix.plugins.mcp-proxy.json")
local transport = require("apisix.plugins.mcp-proxy.transport")
local template = require("apisix.plugins.mcp-proxy.template")

local json_array = json.array
local json_is_array = json.is_array
local json_is_object = json.is_object
local math_min = math.min
local ngx_now = ngx.now
local ngx_thread_spawn = ngx.thread.spawn
local ngx_thread_wait = ngx.thread.wait
local table_sort = table.sort
local template_compile = template.compile
local transport_initialize = transport.initialize
local transport_request = transport.request

local discovery = {}
local KINDS = {
    tools = {
        method = "tools/list",
        cap = "tools",
        field = "tools",
        key = "name",
        aliases = "tool_aliases",
    },
    prompts = {
        method = "prompts/list",
        cap = "prompts",
        field = "prompts",
        key = "name",
        aliases = "prompt_aliases",
    },
    resources = {
        method = "resources/list",
        cap = "resources",
        field = "resources",
        key = "uri",
        hidden = "hidden_resource_uris",
    },
    templates = {
        method = "resources/templates/list",
        cap = "resources",
        field = "resourceTemplates",
        key = "uriTemplate",
        hidden = "hidden_resource_templates",
    },
}
discovery.kinds = KINDS


--- Create a sanitized catalog failure with an HTTP gateway status.
-- @param message string Public diagnostic without upstream secrets.
-- @return string, table Diagnostic and HTTP failure metadata.
local function failure(message)
    return message, { status = 502, message = message }
end


--- Run bounded discovery workers and return complete ordered results.
-- Waits for all workers. Failures prefer 401, then 403, then configured server order.
-- @param conf table Configuration with servers and max_concurrency.
-- @param fn function Callback(server, index): value, error string, failure metadata.
-- @return table|nil Results; on failure nil, diagnostic string and HTTP failure metadata.
function discovery.parallel(conf, fn)
    local results, errors, next_index = table_new(#conf.servers, 0), table_new(#conf.servers, 0), 1
    local threads = table_new(math_min(conf.max_concurrency, #conf.servers), 0)


    --- Drain the shared server queue without retrying failed work.
    -- @return nil Populates results or errors at each configured server index.
    local function discover_worker()
        while next_index <= #conf.servers do
            local i = next_index
            next_index = next_index + 1
            local ok, value, err, detail = pcall(fn, conf.servers[i], i)
            if not ok then
                errors[i] = { status = 502, message = "Upstream processing failed" }

            elseif not value then
                errors[i] = detail
                    or { status = 502, message = err or "Upstream processing failed" }

            else
                results[i] = value
            end
        end
    end
    for _ = 1, math_min(conf.max_concurrency, #conf.servers) do
        threads[#threads + 1] = ngx_thread_spawn(discover_worker)
    end
    local worker_failed = false
    for _, thread in ipairs(threads) do
        local ok = ngx_thread_wait(thread)
        if not ok then
            worker_failed = true
        end
    end
    -- Never publish a subset. Auth precedence: 401, 403, then first server error.
    for _, status in ipairs({ 401, 403 }) do
        for i = 1, #conf.servers do
            if errors[i] and errors[i].status == status then
                return nil, errors[i].message, errors[i]
            end
        end
    end
    for i = 1, #conf.servers do
        if errors[i] then
            return nil, errors[i].message, errors[i]
        end
    end
    if worker_failed then
        return nil, failure("Upstream discovery worker failed")
    end
    return results
end


--- Fetch every page of one supported catalog under a shared deadline.
-- Rejects invalid entries, repeated cursors and configured size/page overflows.
-- @param conf table Configuration containing catalog limits.
-- @param ctx table APISIX request context.
-- @param server table One configured upstream descriptor.
-- @param init table Validated upstream initialization result.
-- @param kind string Catalog kind present in kinds.
-- @param deadline number Absolute ngx.now() deadline in seconds.
-- @return table|nil Marked JSON array; on failure nil, diagnostic and HTTP metadata.
local function list(conf, ctx, server, init, kind, deadline)
    local spec = KINDS[kind]
    local items = json_array()
    if not init.capabilities[spec.cap] then
        return items
    end
    local cursor, seen = nil, {}
    for page = 1, conf.max_pages do
        local params = {}
        if cursor then
            params.cursor = cursor
        end
        local reply, err, detail = transport_request(
            conf,
            ctx,
            server,
            { jsonrpc = "2.0", id = "proxy-list-" .. page, method = spec.method, params = params },
            deadline
        )
        if not reply then
            return nil, err, detail
        end
        if reply.error then
            return nil, failure("Upstream catalog returned a JSON-RPC error")
        end
        local result = reply.result
        if not json_is_object(result) or not json_is_array(result[spec.field]) then
            return nil, failure("Invalid upstream catalog")
        end
        for _, item in ipairs(result[spec.field]) do
            if
                not json_is_object(item)
                or type(item[spec.key]) ~= "string"
                or item[spec.key] == ""
            then
                return nil, failure("Invalid catalog entry")
            end
            if kind == "tools" and not json_is_object(item.inputSchema) then
                return nil, failure("Invalid tool schema")
            end
            if item.execution ~= nil and not json_is_object(item.execution) then
                return nil, failure("Invalid tool execution metadata")
            end
            if item.execution and item.execution.taskSupport == "required" then
                return nil, failure("Tool requires unsupported task execution")
            end
            ctx.mcp_discovery_entries = (ctx.mcp_discovery_entries or 0) + 1
            if ctx.mcp_discovery_entries > conf.max_discovery_entries then
                ctx.mcp_discovery_failed = true
                return nil, failure("Aggregate discovery entry limit exceeded")
            end
            items[#items + 1] = item
            if #items > conf.max_entries then
                return nil, failure("Catalog entry limit exceeded")
            end
        end
        cursor = result.nextCursor
        if cursor == nil then
            return items
        end
        if type(cursor) ~= "string" or seen[cursor] then
            return nil, failure("Invalid or repeated upstream cursor")
        end
        seen[cursor] = true
    end
    return nil, failure("Catalog page limit exceeded")
end


--- Discover and merge requested catalogs, aliases and ownership maps.
-- Rejects collisions and partial results. Renames entries in fresh response tables.
-- No catalog content is cached by this function.
-- @param conf table Validated route configuration.
-- @param ctx table APISIX request context.
-- @param wanted table Ordered list of catalog kinds to discover.
-- @return table|nil Catalogs and routing; on failure nil, diagnostic and HTTP metadata.
function discovery.fetch(conf, ctx, wanted)


    --- Initialize and fetch the requested catalogs for one upstream.
    -- @param server table Configured upstream descriptor.
    -- @return table|nil Catalogs; else nil, diagnostic and HTTP metadata.
    local function fetch_server(server)
        local deadline = ngx_now()
            + (
                (server.timeouts and server.timeouts.discovery_total)
                or conf.timeouts.discovery_total
            )
        deadline = math_min(deadline, ctx.mcp_deadline)
        local init, why, init_detail = transport_initialize(conf, ctx, server, deadline)
        if not init then
            return nil, why, init_detail
        end
        local result = {}
        for _, kind in ipairs(wanted) do
            local list_detail
            result[kind], why, list_detail = list(conf, ctx, server, init, kind, deadline)
            if not result[kind] then
                return nil, why, list_detail
            end
        end
        return result
    end
    ctx.mcp_discovering = true
    local results, err, detail = discovery.parallel(conf, fetch_server)
    ctx.mcp_discovering = false
    if not results then
        return nil, err, detail
    end
    local catalogs, routing = table_new(0, #wanted), table_new(0, #wanted)
    for _, kind in ipairs(wanted) do
        local spec = KINDS[kind]
        local merged, owners, patterns = json_array(), {}, {}
        for index, server in ipairs(conf.servers) do
            local hidden = {}
            for _, key in ipairs(server[spec.hidden] or {}) do
                hidden[key] = true
            end
            for _, item in ipairs(results[index][kind]) do
                local original = item[spec.key]
                local alias = spec.aliases and (server[spec.aliases] or {})[original]
                if alias ~= json.null and not hidden[original] then
                    local public = alias or original
                    if owners[public] then
                        return nil, failure("Catalog collision after aliases and filters")
                    end
                    local pattern
                    if kind == "templates" then
                        pattern, err = template_compile(public)
                        if not pattern then
                            return nil, failure(err)
                        end
                        if patterns[pattern] then
                            return nil,
                                failure("Equivalent resource templates have multiple owners")
                        end
                        patterns[pattern] = true
                    end
                    owners[public] = { server = index, original = original, pattern = pattern }
                    item[spec.key] = public
                    merged[#merged + 1] = item
                    if #merged > conf.max_entries then
                        return nil, failure("Merged catalog entry limit exceeded")
                    end
                end
            end
        end


        --- Order public catalog entries deterministically by their protocol key.
        -- @param left table First catalog entry.
        -- @param right table Second catalog entry.
        -- @return boolean Whether left precedes right.
        local function compare_entries(left, right)
            return left[spec.key] < right[spec.key]
        end
        table_sort(merged, compare_entries)
        catalogs[kind] = merged
        routing[kind] = owners
    end
    return { catalogs = catalogs, routing = routing }
end
return discovery
