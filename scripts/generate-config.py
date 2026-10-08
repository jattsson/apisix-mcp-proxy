"""Create a self-contained standalone APISIX test configuration (JSON is YAML)."""
import copy
import json
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = root / '.test/conf'
out.mkdir(parents=True, exist_ok=True)
test_plugins=root / '.test/lua/apisix/plugins'
test_plugins.mkdir(parents=True,exist_ok=True)
shutil.copyfile(root / 'fixtures/test-auth.lua',test_plugins / 'test-auth.lua')
config = {
    'apisix': {'node_listen': 9080, 'enable_admin': False, 'enable_control': False, 'trusted_addresses':['127.0.0.1','10.231.241.10'], 'extra_lua_path': '/opt/mcp-proxy/?.lua;/opt/tests/?.lua', 'proxy_mode': 'http'},
    'deployment': {'role': 'data_plane', 'role_data_plane': {'config_provider': 'yaml'}},
    'nginx_config': {'worker_processes': 2, 'worker_cpu_affinity': '0', 'error_log_level': 'warn',
        'http': {'real_ip_header':'X-Forwarded-For','real_ip_recursive':'on','real_ip_from':['127.0.0.1','10.231.241.10'],'custom_lua_shared_dict': {'mcp_proxy_tickets': '8m'}},
        'http_server_configuration_snippet': 'proxy_buffering off;\nclient_body_buffer_size 8m;\nlua_check_client_abort on;'},
    'plugins': ['mcp-proxy', 'test-auth', 'ip-restriction', 'openid-connect', 'redirect'], 'stream_plugins': []
}
metadata = {'resource': 'https://gateway.example.test:9443/mcp/farm',
    'metadata_url': 'https://gateway.example.test:9443/.well-known/oauth-protected-resource/mcp/farm',
    'authorization_servers': ['https://issuer.example.test'], 'scopes_supported': ['mcp:read']}
plugin = {'server_info': {'name': 'farm-mcp', 'version': '1.0.0'}, 'auth_metadata': metadata,
    'instructions': 'Farm tools', 'servers': [
        {'upstream_id': 'a', 'mcp_path': '/mcp', 'tool_aliases': {'echo': 'echo_a', 'second': None}},
        {'upstream_id': 'b', 'mcp_path': '/mcp', 'tool_aliases': {'echo': 'echo_b', 'second': 'second_b'}, 'prompt_aliases': {'prompt': 'prompt_b'}, 'hidden_resource_uris': ['fixture://adversary/one'], 'hidden_resource_templates': ['fixture://adversary/{id}']}
    ]}
routes = [
    {'id': 'bridge', 'uri': '/_mcp_proxy_internal', 'host': 'mcp-proxy.internal.invalid', 'priority': 20000, 'plugins': {'mcp-proxy': {'mode': 'bridge'}}},
    {'id': 'farm', 'uri': '/mcp/farm', 'plugins': {'test-auth': {}, 'mcp-proxy': plugin}},
    {'id': 'metadata', 'uri': '/.well-known/oauth-protected-resource/mcp/farm', 'plugins': {'mcp-proxy': {'mode': 'metadata', 'auth_metadata': metadata}}},
]
single = copy.deepcopy(plugin)
single['servers'] = [single['servers'][0]]
routes.append({'id': 'single', 'uri': '/mcp/single', 'plugins': {'test-auth': {}, 'mcp-proxy': single}})
admin = copy.deepcopy(single)
admin['server_info']['name'] = 'admin-mcp'
admin['servers'][0]['tool_aliases'] = {'echo': 'admin_echo', 'second': None}
routes.append({'id': 'admin', 'uri': '/mcp/admin', 'plugins': {'test-auth': {}, 'mcp-proxy': admin}})
standalone = {'routes': routes, 'upstreams': [
    {'id': 'a', 'type': 'roundrobin', 'nodes': {'adversary:8080': 1}, 'retries': 5, 'pass_host': 'rewrite', 'upstream_host': 'fixture.internal'},
    {'id': 'b', 'type': 'roundrobin', 'nodes': {'adversary:8080': 1}, 'retries': 5, 'pass_host': 'node'}]}
java_plugin=copy.deepcopy(plugin)
java_plugin['servers'][0]['upstream_id']='java-a'
java_plugin['servers'][1]['upstream_id']='java-b'
java_plugin['servers'][1]['hidden_resource_uris']=[]
java_plugin['servers'][1]['hidden_resource_templates']=[]
routes.append({'id':'java','uri':'/mcp/java','plugins':{'test-auth':{},'mcp-proxy':java_plugin}})
for name in ('java-a','java-b'):
    standalone['upstreams'].append({'id':name,'type':'roundrobin','nodes':{name+':8080':1},'retries':5})
certs=root/'.test/certs'
standalone['ssls']=[{'id':'test-client','type':'client','cert':(certs/'client.crt').read_text(),'key':(certs/'client.key').read_text()}]
for name,target,tls in [
    ('https','secure',{'verify':True,'ca_certs':[(certs/'ca.crt').read_text()]}),
    ('mtls','mtls',{'verify':True,'ca_certs':[(certs/'ca.crt').read_text()],'client_cert_id':'test-client'}),
    ('bad-ca','secure',{'verify':True,'ca_certs':[(certs/'wrong-ca.crt').read_text()]}),
    ('bad-client','mtls',{'verify':True,'ca_certs':[(certs/'ca.crt').read_text()],'client_cert':(certs/'wrong-ca.crt').read_text(),'client_key':(certs/'wrong-ca.key').read_text()})]:
    standalone['upstreams'].append({'id':name,'type':'roundrobin','nodes':{target+':8080':1},'scheme':'https','pass_host':'rewrite','upstream_host':'fixture.internal','tls':tls,'retries':5})
    variant=copy.deepcopy(single)
    variant['servers'][0]['upstream_id']=name
    routes.append({'id':name,'uri':'/mcp/'+name,'plugins':{'test-auth':{},'mcp-proxy':variant}})
oidc={'client_id':'mcp-tests','discovery':'http://oidc:8080/.well-known/openid-configuration','bearer_only':True,'use_jwks':True,
    'claim_validator':{'issuer':{'valid_issuers':['https://issuer.example.test']},'audience':{'required':True,'match_with_client_id':True}},
    'set_access_token_header':False,'set_id_token_header':False,'set_userinfo_header':False}
routes.append({'id':'oidc','uri':'/mcp/oidc','plugins':{'openid-connect':oidc,'mcp-proxy':copy.deepcopy(single)}})
# Separate routes to exercise collision, bounded parallelism and total deadlines.
for name,changes in [('collision',{}),('serial',{'max_concurrency':1}),('timeout',{'timeouts':{'connect':1,'discovery_total':1,'read_idle':1,'operation_total':1}})]:
    variant=copy.deepcopy(plugin)
    variant.update(changes)
    if name=='collision':
        variant['servers'][1]['tool_aliases']['echo']='echo_a'
    routes.append({'id':name,'uri':'/mcp/'+name,'plugins':{'test-auth':{},'mcp-proxy':variant}})
for name,nodes,checks in [('balanced',{'adversary:8080':1,'adversary-2:8080':1},None),
    ('healthy',{'adversary:8080':1,'adversary-2:1':1},{'active':{'type':'http','http_path':'/health','timeout':1,'healthy':{'interval':1,'successes':1},'unhealthy':{'interval':1,'tcp_failures':1,'http_failures':1}}})]:
    upstream={'id':name,'type':'roundrobin','nodes':nodes,'retries':5}
    if checks:
        upstream['checks']=checks
    standalone['upstreams'].append(upstream)
    variant=copy.deepcopy(single)
    variant['servers'][0]['upstream_id']=name
    routes.append({'id':name,'uri':'/mcp/'+name,'plugins':{'test-auth':{},'mcp-proxy':variant}})
for name,allowed in [('ip','10.231.241.1'),('denied-ip','203.0.113.99')]:
    routes.append({'id':name,'uri':'/mcp/'+name,'plugins':{'test-auth':{},'ip-restriction':{'whitelist':[allowed]},'mcp-proxy':copy.deepcopy(single)}})
# Public host redirects must never capture authenticated internal fan-out.
public_hosts = ['first.example.test', 'second.example.test']
routes.append({'id':'public-redirect','uri':'/*','hosts':public_hosts,'priority':10000,
    'plugins':{'redirect':{'http_to_https':True}}})
routes.append({'id':'hostless-fallback','uri':'/_mcp_proxy_internal','priority':10000,
    'plugins':{'redirect':{'uri':'https://fallback.example.test','ret_code':302}}})
for policy in ('pass', 'node', 'rewrite'):
    upstream_id = 'host-' + policy
    upstream = {'id':upstream_id,'type':'roundrobin','nodes':{'adversary:8080':1},
        'pass_host':policy}
    if policy == 'rewrite':
        upstream['upstream_host'] = 'fixture.internal'
    standalone['upstreams'].append(upstream)
    variant = copy.deepcopy(single)
    variant['servers'][0]['upstream_id'] = upstream_id
    routes.append({'id':upstream_id,'uri':'/mcp/'+upstream_id,'hosts':public_hosts,
        'priority':20001,'plugins':{'test-auth':{},'mcp-proxy':variant}})
(out / 'config.yaml').write_text(json.dumps(config, indent=2))
(out / 'apisix.yaml').write_text(json.dumps(standalone, indent=2) + '\n#END\n')
print(out)
