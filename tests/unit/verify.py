"""Independent JSON parser checks the output produced by real OpenResty Lua."""
import json
import sys
from decimal import Decimal
result=json.load(sys.stdin, parse_float=Decimal)
value=result['roundtrip']
assert value['tools']==[] and isinstance(value['tools'],list)
assert value['properties']=={} and isinstance(value['properties'],dict)
assert value['required']==[]
assert value['nested']==[None,False,0,{},[]]
assert value['nested'][1] is False
assert value['aliases']['hidden'] is None
print(f"OpenResty helpers: {result['checks']} assertions; independent JSON type verification passed")

# Independently verify exact JSON numbers after the Lua decode/encode roundtrip.
numbers=result['numbers']
assert numbers['safe']==9007199254740991
assert numbers['beyond']==9007199254740993
assert numbers['decimal']==Decimal('1.2345678901234567')
assert numbers['exponent']==Decimal('1.25e-4')
assert numbers['maximum']==9223372036854775807
assert numbers['minimum']==-9223372036854775808
print('OpenResty numeric boundaries: exact integers, decimals and exponents preserved')
