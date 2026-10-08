local require = require
local assert = assert
local print = print

local json = require("apisix.plugins.mcp-proxy.json")
local auth = require("apisix.plugins.mcp-proxy.auth")
local template = require("apisix.plugins.mcp-proxy.template")
local sse = require("apisix.plugins.mcp-proxy.sse")

local auth_challenge = auth.challenge
local json_decode = json.decode
local json_encode = json.encode
local json_is_array = json.is_array
local json_is_object = json.is_object
local sse_feed = sse.feed
local sse_new = sse.new
local template_compile = template.compile
local template_is_match = template.is_match

local checks = 0


--- Assert a helper invariant and increment the independently checked count.
-- @param value any Truthy assertion result; false/nil raises immediately.
-- @return nil Updates the local assertion counter.
local function check(value)
    assert(value)
    checks = checks + 1
end
local sample = assert(
    json_decode(
        '{"tools":[],"properties":{},"required":[],'
            .. '"nested":[null,false,0,{},[]],"aliases":{"hidden":null}}'
    )
)
check(json_is_array(sample.tools))
check(json_is_object(sample.properties))
check(sample.aliases.hidden == json.null)
local url = "https://example.test/.well-known/oauth-protected-resource/mcp"
local challenge = assert(
    auth_challenge(
        'Basic realm="one,two", Bearer error="insufficient_scope", scope="read write",'
            .. ' error_description="a\\"b,c", resource_metadata="https://old.test"',
        url
    )
)
check(challenge:find('scope="read write"', 1, true))
check(challenge:find('Basic realm="one,two"', 1, true))
check(not challenge:find("old.test", 1, true))
check(challenge:find('error_description="a\\"b,c"', 1, true))
check(not auth_challenge('Bearer error="broken', url))
local pattern = assert(template_compile("fixture://host/{id}"))
check(template_is_match(pattern, "fixture://host/a%2Fb"))
check(not template_is_match(pattern, "fixture://host/a/b"))
check(not template_is_match(pattern, "fixture://host/a%G0"))
check(not template_is_match(pattern, "fixture://host/a%0G"))
check(not template_compile("fixture://host/{+path}"))
check(not template_compile("fixture://host/{id*}"))
check(not template_compile("fixture://host/{id:2}"))
check(not template_compile("fixture://host/{broken"))
local count = 0
local parser = sse_new(2048)
local stream = ': comment\rdata: {"jsonrpc":"2.0",\r\ndata: "id":0,"result":{"content":[]}}\r\n\r\n'


--- Verify the fragmented event after the parser assembles it.
-- @param value table Decoded JSON-RPC response.
-- @return boolean True after all assertions pass.
local function verify_event(value)
    count = count + 1
    check(value.id == 0)
    check(json_is_array(value.result.content))
    return true
end
for i = 1, #stream do
    assert(sse_feed(parser, stream:sub(i, i), verify_event))
end
check(count == 1)
print(json_encode({ checks = checks, roundtrip = sample }))
