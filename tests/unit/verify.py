"""Independent JSON parser checks the output produced by real OpenResty Lua."""
import json
import sys
result=json.load(sys.stdin)
value=result['roundtrip']
assert value['tools']==[] and isinstance(value['tools'],list)
assert value['properties']=={} and isinstance(value['properties'],dict)
assert value['required']==[]
assert value['nested']==[None,False,0,{},[]]
assert value['nested'][1] is False
assert value['aliases']['hidden'] is None
print(f"OpenResty helpers: {result['checks']} assertions; independent JSON type verification passed")
