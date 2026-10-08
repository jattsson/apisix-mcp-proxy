"""Read dependency and transport evidence from an existing Spring Boot jar."""
import io
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as jar:
    libs = [n for n in jar.namelist() if n.startswith('BOOT-INF/lib/') and ('mcp' in n or 'spring-ai' in n)]
    print(json.dumps(libs, indent=2))
    for name in jar.namelist():
        if name.startswith('BOOT-INF/classes/application') and name.endswith(('.yaml', '.yml', '.properties')):
            print(name)
            for line in jar.read(name).decode().splitlines():
                if any(s in line.lower() for s in ('mcp', 'stateless', 'streamable', 'protocol')):
                    print(line)
    for name in libs:
        if '/mcp-core-' in name:
            with zipfile.ZipFile(io.BytesIO(jar.read(name))) as lib:
                for entry in lib.namelist():
                    if entry.endswith('pom.properties'):
                        print(lib.read(entry).decode())
