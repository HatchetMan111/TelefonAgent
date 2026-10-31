import re, sys

path = sys.argv[1]
text = open(path).read()

def set_section_enabled(text, section, enabled):
    pattern = r'(?m)^\[' + re.escape(section) + r'\].*?(?=^\[|\Z)'
    m = re.search(pattern, text, flags=re.S)
    if not m:
        return text
    sec = m.group(0)
    if re.search(r'(?m)^enabled\s*=', sec):
        sec = re.sub(r'(?m)^enabled\s*=.*$', f'enabled = {"true" if enabled else "false"}', sec)
    else:
        sec = sec.rstrip('\n') + f'\nenabled = {"true" if enabled else "false"}\n'
    return re.sub(pattern, lambda _: sec, text, flags=re.S, count=1)

text = set_section_enabled(text, 'analytics', False)
text = set_section_enabled(text, 'storage.vector', False)
text = set_section_enabled(text, 'vector', False)
text = set_section_enabled(text, 'studio', True)
open(path, 'w').write(text)
print('config patch ok')
