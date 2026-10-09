import json
import unittest
import urllib.request
import urllib.error
import http.client
import time
import ssl
import concurrent.futures
import subprocess
import socket
from pathlib import Path

BASE='http://127.0.0.1:19080'
ROOT=Path(__file__).resolve().parents[2]

def stats(reset=False):
    req=urllib.request.Request('http://127.0.0.1:18080/'+('reset' if reset else 'stats'),b'{}' if reset else None)
    with urllib.request.urlopen(req) as response:
        return json.load(response)

def request(method='tools/list',params=None,path='/mcp/farm',headers=None,raw=None,port=19080):
    body=raw if raw is not None else json.dumps({'jsonrpc':'2.0','id':7,'method':method,'params':params or {}}).encode()
    h={'Authorization':'Bearer alice','Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'}
    h.update(headers or {})
    h={key:value for key,value in h.items() if value is not None}
    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=20)
    try:
        connection.request('POST',path,body,h)
        response=connection.getresponse()
        return response.status,dict(response.headers),response.read()
    finally:
        connection.close()

class GatewayTests(unittest.TestCase):
    def test_01_metadata_auth_no_default_upstream(self):
        with urllib.request.urlopen(BASE+'/.well-known/oauth-protected-resource/mcp/farm') as r:
            self.assertEqual(json.load(r)['resource'],'https://gateway.example.test:9443/mcp/farm')
        status,headers,body=request(headers={'Authorization':'bad'})
        self.assertEqual(status,401,body)
        self.assertIn('resource_metadata=',headers.get('WWW-Authenticate',''))
        self.assertIn('error_description="missing, expired or invalid audience"',headers['WWW-Authenticate'])

    def test_02_initialize(self):
        status,h,body=request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}})
        self.assertEqual(status,200,body)
        result=json.loads(body)['result']
        self.assertEqual(result['capabilities'],{'tools':{},'prompts':{},'resources':{}})
        self.assertNotIn('Mcp-Session-Id',h)

    def test_03_catalog_alias_pagination(self):
        status,h,body=request()
        self.assertEqual(status,200,body)
        tools=json.loads(body)['result']['tools']
        self.assertEqual([t['name'] for t in tools],['echo_a','echo_b','second_b'])
        self.assertEqual(tools[0]['inputSchema']['properties'],{})
        self.assertEqual(tools[0]['inputSchema']['required'],[])

    def test_04_cold_operation_roundtrip(self):
        args={'nested':[[],{},None,False,0]}
        status,h,body=request('tools/call',{'name':'echo_a','arguments':args},headers={'X-Tenant':'cold'})
        self.assertEqual(status,200,body)
        result=json.loads(body)['result']
        self.assertEqual(result['content'],[])
        self.assertEqual(result['structuredContent']['arguments'],args)
        self.assertIs(result['structuredContent']['false'],False)
        self.assertEqual(result['structuredContent']['object'],{})

    def test_05_hidden_original(self):
        for name in ('echo','second'):
            status,h,body=request('tools/call',{'name':name},path='/mcp/single',headers={'X-Tenant':'never-listed-'+name})
            self.assertEqual(status,400,body)

    def test_06_auth_error_classification(self):
        for mode,status in [('401',401),('403',403),('429',429),('502',502)]:
            actual,h,body=request(headers={'X-Fixture-Mode':mode})
            self.assertEqual(actual,status,body)
            if status in (401,403):
                self.assertIn('resource_metadata=',h['WWW-Authenticate'])
            if status==403:
                self.assertIn('scope="mcp:write"',h['WWW-Authenticate'])
            if status==429:
                self.assertEqual(h['Retry-After'],'3')

    def test_07_no_partial_invalid_catalog(self):
        for mode in ('bad-catalog','cursor-loop','large','task','session','malformed-json','upstream-gzip'):
            status,h,body=request(headers={'X-Fixture-Mode':mode})
            self.assertEqual(status,502,(mode,body))
            self.assertIn('error',json.loads(body))

    def test_08_fragmented_sse(self):
        status,h,body=request(headers={'X-Fixture-Mode':'sse'})
        self.assertEqual(status,200,body)
        self.assertEqual(len(json.loads(body)['result']['tools']),3)
        status,h,body=request('tools/call',{'name':'echo_a','arguments':{}},headers={'X-Fixture-Mode':'sse'})
        self.assertEqual(status,200,body)
        self.assertIn(b'notifications/progress',body)
        self.assertIn(b'"id": 7',body)
        messages=[]
        for event in body.decode().split('\n\n'):
            payload='\n'.join(line[6:] for line in event.splitlines() if line.startswith('data: '))
            if payload:
                messages.append(json.loads(payload))
        self.assertEqual(messages[-1]['id'],7)
        self.assertEqual(messages[-1]['result']['content'],[])

    def test_09_no_standalone_sse(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(BASE+'/mcp/farm',headers={'Authorization':'Bearer alice'}))
        self.assertEqual(error.exception.code,405)
        error.exception.close()
        self.assertEqual(request('not/a/method')[0],400)

    def test_10_compression_and_invalid_json(self):
        self.assertEqual(request(headers={'Content-Encoding':'gzip'},raw=b'bad gzip')[0],415)
        self.assertEqual(request(raw=b'{broken')[0],400)

    def test_11_route_isolation(self):
        status,h,body=request(path='/mcp/admin')
        self.assertEqual(status,200,body)
        self.assertEqual([x['name'] for x in json.loads(body)['result']['tools']],['admin_echo'])

    def test_12_real_java_sdk(self):
        for method,field,count in [('tools/list','tools',3),('prompts/list','prompts',2),('resources/list','resources',2),('resources/templates/list','resourceTemplates',2)]:
            status,h,body=request(method,path='/mcp/java')
            self.assertEqual(status,200,body)
            self.assertEqual(len(json.loads(body)['result'][field]),count)
        status,h,body=request('tools/call',{'name':'echo_b','arguments':{'nested':[[],{},None,False,0]}},path='/mcp/java')
        self.assertEqual(status,200,body)
        result=json.loads(body)['result']['structuredContent']
        self.assertEqual(result['fixture'],'java-b')
        self.assertEqual(result['arguments']['nested'],[[],{},None,False,0])
        for method,params in [('prompts/get',{'name':'prompt_b'}),('resources/read',{'uri':'fixture://java-b/unlisted'})]:
            status,h,body=request(method,params,path='/mcp/java')
            self.assertEqual(status,200,body)

    def test_13_tls_and_mtls(self):
        for path,expected in [('/mcp/https',200),('/mcp/mtls',200),('/mcp/bad-ca',502),('/mcp/bad-client',502)]:
            for method,params in [('tools/list',{}),('tools/call',{'name':'echo_a','arguments':{}})]:
                status,h,body=request(method,params,path=path)
                self.assertEqual(status,expected,(path,body))

    def test_14_real_oidc_validation(self):
        tokens=json.loads((ROOT/'.test/certs/tokens.json').read_text())
        for kind,token in tokens.items():
            status,h,body=request(path='/mcp/oidc',headers={'Authorization':'Bearer '+token})
            self.assertEqual(status,200 if kind=='valid' else (403 if kind=='audience' else 401),(kind,body))
            if kind!='valid':
                self.assertIn('resource_metadata=',h.get('WWW-Authenticate',''))

    def test_15_no_write_retries(self):
        for variant,path,expected in [('lost-write','/mcp/single',502),('write-500','/mcp/single',502),('write-timeout','/mcp/timeout',504)]:
            stats(True)
            status,h,body=request('tools/call',{'name':'echo_a'},path=path,headers={'X-Fixture-Mode':variant})
            self.assertEqual(status,expected,body)
            self.assertEqual(stats()['writes'],1)

    def test_16_parallel_and_limit(self):
        for path,peak in [('/mcp/farm',2),('/mcp/serial',1)]:
            stats(True)
            status,h,body=request(path=path,headers={'X-Fixture-Mode':'delay'})
            self.assertEqual(status,200,body)
            self.assertEqual(stats()['peak'],peak)

    def test_17_timeout_and_collision(self):
        self.assertEqual(request(path='/mcp/timeout',headers={'X-Fixture-Mode':'timeout'})[0],504)
        self.assertEqual(request(path='/mcp/collision')[0],502)
        self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/collision')[0],502)

    def test_18_headers_and_error_result(self):
        stats(True)
        status,h,body=request('tools/call',{'name':'echo_a','arguments':{'hello':'value'}},path='/mcp/single',headers={
            'Authorization':'Bearer bob','X-Tenant':'tenant-a','Traceparent':'00-12345678901234567890123456789012-1234567890123456-01',
            'Accept-Language':'sv','Connection':'close, X-Remove-Me','X-Remove-Me':'secret',
            'X-Forwarded-For':'203.0.113.99','X-Fixture-Mode':'tool-error'})
        self.assertEqual(status,200,body)
        self.assertTrue(json.loads(body)['result']['isError'])
        call=[x for x in stats()['calls'] if x['method']=='tools/call'][0]
        h={k.lower():v for k,v in call['headers'].items()}
        self.assertEqual(h['authorization'],'Bearer bob')
        self.assertEqual(h['x-tenant'],'tenant-a')
        self.assertEqual(h['accept-language'],'sv')
        self.assertEqual(h['host'],'fixture.internal')
        self.assertNotIn('x-remove-me',h)
        self.assertNotIn('203.0.113.99',h.get('x-forwarded-for',''))
        self.assertNotEqual(h['x-real-ip'],'127.0.0.1')
        self.assertEqual(call['body']['params']['name'],'echo')

    def test_19_warm_owner_only(self):
        connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=20)
        h={'Authorization':'Bearer alice','Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25','X-Tenant':'warm'}
        def send(method,params):
            connection.request('POST','/mcp/farm',json.dumps({'jsonrpc':'2.0','id':8,'method':method,'params':params}),h)
            r=connection.getresponse()
            body=r.read()
            self.assertEqual(r.status,200,body)
        try:
            send('tools/list',{})
            stats(True)
            send('tools/call',{'name':'echo_a','arguments':{}})
            calls=stats()['calls']
            self.assertEqual([x['method'] for x in calls],['initialize','notifications/initialized','tools/call'])
        finally:
            connection.close()

    def test_20_capabilities_and_resource_blocks(self):
        status,h,body=request('prompts/list',headers={'X-Fixture-Mode':'no-prompts'})
        self.assertEqual(status,200,body)
        self.assertEqual(json.loads(body)['result']['prompts'],[])
        self.assertEqual(request('resources/read',{'uri':'fixture://adversary/secret'})[0],400)
        self.assertEqual(request('resources/read',{'uri':'unknown://unowned'},path='/mcp/java')[0],400)

    def test_21_balancing_and_health(self):
        nodes=set()
        for _ in range(10):
            status,h,body=request('tools/call',{'name':'echo_a'},path='/mcp/balanced')
            self.assertEqual(status,200,body)
            nodes.add(json.loads(body)['result']['structuredContent']['node'])
        self.assertEqual(nodes,{'a','b'})
        # Let active health checks establish status; no operation retry is used.
        healthy=0
        for _ in range(30):
            healthy=healthy+1 if request(path='/mcp/healthy')[0]==200 else 0
            if healthy>=5:
                break
            time.sleep(0.5)
        self.assertGreaterEqual(healthy,5,'APISIX health status never converged')
        for _ in range(4):
            self.assertEqual(request(path='/mcp/healthy')[0],200)
            self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/healthy')[0],200)

    def test_22_instances_and_workers(self):
        workers=set()
        for port in (19080,19081):
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                results=list(pool.map(lambda n: request('tools/call',{'name':'echo_b','arguments':{'n':n}},path='/mcp/java',port=port),range(12)))
            for status,h,body in results:
                self.assertEqual(status,200,body)
                self.assertEqual(json.loads(body)['result']['structuredContent']['fixture'],'java-b')
                workers.add((port,h['X-Test-Worker']))
        self.assertGreaterEqual(len(workers),4)
        subprocess.run(['docker','compose','restart','gateway-2'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
        for _ in range(30):
            try:
                if request('tools/call',{'name':'echo_b'},path='/mcp/java',port=19081)[0]==200:
                    break
            except OSError:
                pass
            time.sleep(0.2)
        else:
            self.fail('Restarted instance did not recover through fresh discovery')

    def test_23_https_reverse_proxy_context(self):
        stats(True)
        context=ssl.create_default_context(cafile=str(ROOT/'.test/certs/ca.crt'))
        connection=http.client.HTTPSConnection('127.0.0.1',9443,context=context,timeout=20)
        try:
            h={'Host':'gateway.example.test:9443','Authorization':'Bearer alice','Content-Type':'application/json','MCP-Protocol-Version':'2025-11-25','X-Tenant':'through-tls','Traceparent':'trace-test','X-Forwarded-For':'203.0.113.99'}
            connection.request('POST','/mcp/single',json.dumps({'jsonrpc':'2.0','id':'tls','method':'tools/call','params':{'name':'echo_a'}}),h)
            response=connection.getresponse()
            self.assertEqual(response.status,200,response.read())
            calls=[x for x in stats()['calls'] if x['method']=='tools/call']
            headers={k.lower():v for k,v in calls[-1]['headers'].items()}
            self.assertEqual(headers['x-forwarded-proto'],'https')
            self.assertEqual(headers['x-forwarded-port'],'9443')
            self.assertEqual(headers['x-forwarded-host'],'gateway.example.test:9443')
            self.assertEqual(headers['x-tenant'],'through-tls')
            self.assertEqual(headers['x-real-ip'],headers['x-forwarded-for'].split(',')[0].strip())
            self.assertNotIn('203.0.113.99',headers['x-forwarded-for'])
            h['Authorization']='invalid'
            connection.request('POST','/mcp/single',b'{}',h)
            response=connection.getresponse()
            response.read()
            self.assertEqual(response.status,401)
            self.assertIn('https://gateway.example.test:9443/.well-known/',response.getheader('WWW-Authenticate'))
        finally:
            connection.close()

    def test_24_generation_during_discovery(self):
        config_path=ROOT/'.test/conf/apisix.yaml'
        original=config_path.read_text()
        config=json.loads(original.split('\n#END')[0])
        stats(True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            old=pool.submit(request,path='/mcp/single',headers={'X-Fixture-Mode':'slow'})
            for _ in range(60):
                if stats()['active']:
                    break
                time.sleep(0.05)
            try:
                route=next(r for r in config['routes'] if r['id']=='single')
                route['plugins']['mcp-proxy']['servers'][0]['tool_aliases']['echo']='after_reload'
                config_path.write_text(json.dumps(config)+'\n#END\n')
                time.sleep(2)
                old.result(timeout=15)
                for port in (19080,19081):
                    for _ in range(1):
                        status,h,body=request(path='/mcp/single',headers={'X-Fixture-Mode':'slow'},port=port)
                        self.assertEqual(status,200,body)
                        self.assertEqual([x['name'] for x in json.loads(body)['result']['tools']],['after_reload'])
                    self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/single',headers={'X-Fixture-Mode':'slow'},port=port)[0],400)
                    self.assertEqual(request('tools/call',{'name':'after_reload'},path='/mcp/single',headers={'X-Fixture-Mode':'slow'},port=port)[0],200)
            finally:
                config_path.write_text(original)
                time.sleep(2)

    def test_25_identity_isolation_and_empty_arrays(self):
        h={'X-Catalog-Policy':'isolate'}
        self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/single',headers=h)[0],200)
        for additions in ({'Authorization':'Bearer bob'},{'X-Tenant':'restricted'}):
            headers=h|additions
            status,_,body=request(path='/mcp/single',headers=headers)
            self.assertEqual(status,200,body)
            self.assertEqual(json.loads(body)['result']['tools'],[])
            self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/single',headers=headers)[0],400)

    def test_26_sse_progress_before_result(self):
        connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=3)
        h={'Authorization':'Bearer alice','Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25','X-Fixture-Mode':'sse-wait'}
        try:
            connection.request('POST','/mcp/single',json.dumps({'jsonrpc':'2.0','id':'stream','method':'tools/call','params':{'name':'echo_a','_meta':{'progressToken':7}}}),h)
            response=connection.getresponse()
            self.assertEqual(response.status,200)
            event=[]
            while True:
                line=response.readline()
                if line in (b'\n',b''):
                    break
                event.append(line)
            self.assertIn(b'notifications/progress',b''.join(event))
            self.assertTrue(stats()['waiting'],'Result already finished; progress was buffered')
            with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:18080/release',b'{}')) as r:
                r.read()
            self.assertIn(b'"id": "stream"',response.read())
        finally:
            connection.close()

    def test_27_certificate_reference_rotation(self):
        config_path=ROOT/'.test/conf/apisix.yaml'
        original=config_path.read_text()
        config=json.loads(original.split('\n#END')[0])
        self.assertEqual(request(path='/mcp/mtls')[0],200)
        try:
            cert=next(c for c in config['ssls'] if c['id']=='test-client')
            cert['cert']=(ROOT/'.test/certs/wrong-ca.crt').read_text()
            cert['key']=(ROOT/'.test/certs/wrong-ca.key').read_text()
            config_path.write_text(json.dumps(config)+'\n#END\n')
            time.sleep(2)
            for _ in range(3):
                self.assertEqual(request(path='/mcp/mtls')[0],502)
        finally:
            config_path.write_text(original)
            time.sleep(2)
        self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/mtls')[0],200)

    def test_28_ip_policy_before_proxy(self):
        self.assertEqual(request('tools/call',{'name':'echo_a'},path='/mcp/ip')[0],200)
        self.assertEqual(request(path='/mcp/denied-ip',headers={'X-Forwarded-For':'203.0.113.99'})[0],403)

    def test_29_no_stale_catalog_and_warm_survivor(self):
        connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=15)
        h={'Authorization':'Bearer alice','Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25','X-Tenant':'outage-test'}
        def send(method,params):
            connection.request('POST','/mcp/java',json.dumps({'jsonrpc':'2.0','id':'outage','method':method,'params':params}),h)
            response=connection.getresponse()
            return response.status,json.loads(response.read())
        try:
            self.assertEqual(send('tools/list',{})[0],200)
            subprocess.run(['docker','compose','stop','--timeout','1','java-b'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
            status,body=send('tools/list',{})
            self.assertIn(status,(502,504),body)
            self.assertNotIn('result',body)
            status,body=send('tools/call',{'name':'echo_a'})
            self.assertEqual(status,200,body)
            self.assertEqual(body['result']['structuredContent']['fixture'],'java-a')
        finally:
            connection.close()
            subprocess.run(['docker','compose','start','java-b'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
            for _ in range(30):
                if request(path='/mcp/java')[0]==200:
                    break
                time.sleep(0.2)

    def test_30_upstream_jsonrpc_error(self):
        status,_,body=request('tools/call',{'name':'echo_a'},path='/mcp/single',headers={'X-Fixture-Mode':'rpc-error'})
        self.assertEqual(status,200,body)
        reply=json.loads(body)
        self.assertEqual(reply['id'],7)
        self.assertEqual(reply['error']['code'],-32602)
        self.assertEqual(reply['error']['data'],{'kind':'test'})

    def test_31_client_abort_closes_upstream_stream(self):
        connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=4)
        h={'Authorization':'Bearer alice','Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25','X-Fixture-Mode':'sse-abort'}
        connection.request('POST','/mcp/single',json.dumps({'jsonrpc':'2.0','id':'abort','method':'tools/call','params':{'name':'echo_a','_meta':{'progressToken':7}}}),h)
        response=connection.getresponse()
        self.assertEqual(response.status,200)
        self.assertIn(b'event:',response.readline())
        if connection.sock:
            connection.sock.shutdown(socket.SHUT_RDWR)
        response.close()
        connection.close()
        for _ in range(40):
            if stats().get('stream_aborted'):
                break
            time.sleep(0.05)
        self.assertTrue(stats().get('stream_aborted'),'Upstream continued writing after the client aborted')
        self.assertEqual(request(path='/mcp/single')[0],200)
    def test_32_bridge_routing_multiple_hosts_and_host_policies(self):
        for host in ('first.example.test', 'second.example.test:8443'):
            # Prove the conflicting public route is active.
            self.assertEqual(request(path='/unrelated', headers={'Host':host})[0],308)
            for policy in ('pass', 'node', 'rewrite'):
                stats(True)
                status, _, body = request('tools/call', {'name':'echo_a'},
                    path='/mcp/host-'+policy, headers={'Host':host})
                self.assertEqual(status,200,(host,policy,body))
                call = next(c for c in stats()['calls'] if c['method']=='tools/call')
                headers = {k.lower():v for k,v in call['headers'].items()}
                expected = {'pass':host,'node':'adversary:8080','rewrite':'fixture.internal'}
                self.assertEqual(headers['host'],expected[policy])
                self.assertNotIn('x-mcp-proxy-ticket',headers)
        for ticket in ('', 'a'*64):
            status, _, _ = request(path='/_mcp_proxy_internal', headers={
                'Host':'mcp-proxy.internal.invalid','X-Mcp-Proxy-Ticket':ticket,
                'X-Forwarded-For':'127.0.0.1'})
            self.assertEqual(status,404)

    def test_33_discovery_fallback_and_strict_version_boundary(self):
        stats(True)
        for version in ('2026-07-28', '2025-11-25', '', None):
            status, _, body = request('server/discover',
                headers={'MCP-Protocol-Version':version})
            self.assertEqual(status,404,body)
            self.assertEqual(json.loads(body),{'jsonrpc':'2.0','id':7,
                'error':{'code':-32601,'message':'Method not found'}})
        self.assertEqual(stats()['calls'],[])
        for method in ('tools/list','ping','not/a/method'):
            status, _, body = request(method,headers={'MCP-Protocol-Version':'2026-07-28'})
            self.assertEqual(status,400,body)
            self.assertEqual(json.loads(body)['error']['code'],-32602)
        for invalid in (
            {'jsonrpc':'2.0','method':'server/discover','id':None},
            {'jsonrpc':'2.0','method':'server/discover','id':False},
            {'jsonrpc':'2.0','method':'server/discover','id':7,'params':[]},
            {'jsonrpc':'2.0','method':'server/discover'},
        ):
            self.assertEqual(request(raw=json.dumps(invalid).encode())[0],400)
        self.assertEqual(request('server/discover',headers={'Origin':'https://evil.test'})[0],403)
        self.assertEqual(request('server/discover',path='/mcp/denied-ip')[0],403)
        status, _, body = request('initialize',{'protocolVersion':'2026-07-28',
            'capabilities':{},'clientInfo':{'name':'fallback','version':'1'}},
            headers={'MCP-Protocol-Version':'2026-07-28'})
        self.assertEqual(status,200,body)
        self.assertEqual(json.loads(body)['result']['protocolVersion'],'2025-11-25')

    def test_34_discovery_fallback_requires_oidc_authentication(self):
        self.assertEqual(request('server/discover',path='/mcp/oidc',
            headers={'Authorization':None,'MCP-Protocol-Version':'2026-07-28'})[0],401)
        tokens=json.loads((ROOT/'.test/certs/tokens.json').read_text())
        for name in ('expired','audience','issuer'):
            status, headers, body = request('server/discover',path='/mcp/oidc',
                headers={'Authorization':'Bearer '+tokens[name],
                    'MCP-Protocol-Version':'2026-07-28'})
            self.assertEqual(status,403 if name=='audience' else 401,(name,body))
            self.assertIn('resource_metadata=',headers.get('WWW-Authenticate',''))
        status, _, body = request('server/discover',path='/mcp/oidc',
            headers={'Authorization':'Bearer '+tokens['valid'],
                'MCP-Protocol-Version':'2026-07-28'})
        self.assertEqual(status,404,body)
        self.assertEqual(json.loads(body)['error']['code'],-32601)

    def test_35_late_policy_denies_before_any_upstream_work(self):
        for phase in ('access','before_proxy'):
            for method,params in [('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'test','version':'1'}}),('tools/list',{}),('tools/call',{'name':'echo_a'})]:
                stats(True)
                status,_,body=request(method,params,path='/mcp/deny-'+phase)
                self.assertEqual(status,403,(phase,method,body))
                self.assertEqual(stats()['calls'],[])

    def test_36_aggregate_bounds_apply_to_cold_operations(self):
        for path,headers in [('/mcp/bytes',{'X-Fixture-Mode':'many-pages'}),('/mcp/parallel-bytes',{'X-Fixture-Mode':'many-pages'}),('/mcp/entries',{})]:
            cases=[('tools/list',{}),('tools/call',{'name':'echo_a'})]
            if path=='/mcp/entries':
                cases.append(('resources/read',{'uri':'fixture://adversary/unlisted'}))
            for method,params in cases:
                stats(True)
                status,_,body=request(method,params,path=path,headers=headers)
                self.assertEqual(status,502,body)
                self.assertIn('Aggregate discovery',json.loads(body)['error']['message'])
                calls=stats()['calls']
                self.assertLessEqual(sum(c['method']=='tools/list' for c in calls),4)
                self.assertFalse(any(c['method']=='tools/call' for c in calls))

    def test_37_spooled_and_chunked_request_bodies(self):
        args={'padding':'x'*32768}
        status,_,body=request('tools/call',{'name':'echo_a','arguments':args},path='/mcp/single')
        self.assertEqual(status,200,body)
        self.assertEqual(json.loads(body)['result']['structuredContent']['arguments'],args)
        raw=json.dumps({'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':'echo_a','arguments':args}}).encode()
        for payload,expected in [(raw,200),(b'x'*1048577,413)]:
            connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=20)
            try:
                connection.request('POST','/mcp/single',iter([payload[i:i+1024] for i in range(0,len(payload),1024)]),
                    {'Authorization':'Bearer alice','Content-Type':'application/json','MCP-Protocol-Version':'2025-11-25'},encode_chunked=True)
                response=connection.getresponse()
                self.assertEqual(response.status,expected,response.read())
            finally:
                connection.close()
        self.assertEqual(request(raw=b'x'*1048577,path='/mcp/single')[0],413)

    def test_38_origin_media_timeout_and_schema(self):
        connection=http.client.HTTPConnection('127.0.0.1',19080,timeout=10)
        try:
            connection.request('GET','/mcp/single',headers={'Authorization':'Bearer alice','Origin':'https://evil.test'})
            response=connection.getresponse()
            self.assertEqual(response.status,403,response.read())
        finally:
            connection.close()
        self.assertEqual(request(headers={'X-Fixture-Mode':'media-case'})[0],200)
        self.assertEqual(request(headers={'X-Fixture-Mode':'504'})[0],504)
        self.assertEqual(request(headers={'X-Fixture-Mode':'bad-execution'})[0],502)
        with urllib.request.urlopen(BASE+'/schema-regression') as response:
            self.assertEqual(response.status,200)

    def test_39_public_deadline_includes_discovery(self):
        start=time.monotonic()
        status,_,body=request('tools/call',{'name':'echo_a'},path='/mcp/request-deadline',headers={'X-Fixture-Mode':'slow'})
        self.assertEqual(status,504,body)
        self.assertLess(time.monotonic()-start,2.5)

    def test_40_catalog_ttl_is_not_extended_by_other_kinds(self):
        headers={'X-Tenant':'ttl-regression'}
        # Populate both workers, then refresh only tools while prompts age out.
        for _ in range(12):
            self.assertEqual(request('prompts/list',path='/mcp/short-ttl',headers=headers)[0],200)
        time.sleep(0.6)
        for _ in range(12):
            self.assertEqual(request('tools/list',path='/mcp/short-ttl',headers=headers)[0],200)
        time.sleep(0.6)
        stats(True)
        status,_,body=request('prompts/get',{'name':'prompt'},path='/mcp/short-ttl',headers=headers)
        self.assertEqual(status,200,body)
        self.assertTrue(any(c['method']=='prompts/list' for c in stats()['calls']))

if __name__=='__main__':
    unittest.main(verbosity=2)
