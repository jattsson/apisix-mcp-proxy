--- Test auth module.
-- @module fixtures.test-auth
local ngx = ngx
local tostring = tostring

local ngx_req_get_headers = ngx.req.get_headers
local ngx_worker_id = ngx.worker.id

-- Test-only auth boundary. Never install this plugin in production.
local test_auth =
    { version = 0.1, priority = 2500, name = "test-auth", schema = { type = "object" } }


--- Accept the empty test-auth configuration.
-- @return boolean Always true; this fixture has no configurable fields.
function test_auth.check_schema()
    return true
end


--- Accept only the two synthetic integration-test bearer identities.
-- @param _conf table Unused fixture configuration.
-- @param _ctx table Unused APISIX request context.
-- @return integer|nil 401 with a challenge, or nil to continue processing.
function test_auth.rewrite(_conf, _ctx)
    local token = ngx_req_get_headers().authorization
    if token ~= "Bearer alice" and token ~= "Bearer bob" then
        ngx.header["WWW-Authenticate"] =
            'Bearer error="invalid_token", error_description="missing, expired or invalid audience"'
        return 401
    end
end


--- Expose the serving worker ID for the multiworker integration assertion.
-- @return nil Adds the test-only X-Test-Worker response header.
function test_auth.header_filter()
    ngx.header["X-Test-Worker"] = tostring(ngx_worker_id())
end
return test_auth
