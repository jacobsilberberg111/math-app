"""Add MarginServerToken to the app's Info.plist inside an unsigned .ipa.

usage: python -I patch_ipa.py <in.ipa> <token-file> <out.ipa>
"""
import plistlib, sys, zipfile

src, token_file, dst = sys.argv[1:4]
token = open(token_file, encoding="utf-8").read().strip()
assert len(token) >= 32

with zipfile.ZipFile(src) as zin:
    names = zin.namelist()
    plists = [n for n in names if n.count("/") == 2 and n.startswith("Payload/") and n.endswith(".app/Info.plist")]
    assert len(plists) == 1, plists
    target = plists[0]
    info = plistlib.loads(zin.read(target))
    fmt = plistlib.FMT_BINARY if zin.read(target)[:6] == b"bplist" else plistlib.FMT_XML
    info["MarginServerToken"] = token
    print("app:", target, "| name:", info.get("CFBundleDisplayName"), "| id:", info.get("CFBundleIdentifier"))

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = plistlib.dumps(info, fmt=fmt) if item.filename == target else zin.read(item.filename)
            zout.writestr(item, data)

with zipfile.ZipFile(dst) as z:
    assert plistlib.loads(z.read(target))["MarginServerToken"] == token
print("patched ->", dst)
