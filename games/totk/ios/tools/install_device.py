#!/usr/bin/env python3
"""Sign the unsigned TOTK IPA with your own Xcode team and install it on a connected iPhone / iPad.

A free (Personal Team) Apple ID signs for 7 days, a paid membership for a year: run this again to renew. Reinstalling
with the same team and bundle identifier keeps the saves and the shader cache (they are in the app's Documents).

  python3 games/totk/ios/tools/install_device.py "Tears of the Kingdom.ipa" --device "Jack iPhone"

An IPA built with --ios-game-data documents carries no 17 GB game image: pass --game-data <work>/totk/extracted/v143/
romfs/romfs.bin and it is copied once into the app's Documents/GameData in 1 GiB parts (devicectl drops the connection on
one file that size); a later install skips it while the device holds the same image (romfs.sha256 there).

Xcode needs your Apple ID (Xcode > Settings > Accounts). The provisioning profile comes from a throwaway Xcode project
built with the same bundle identifier and entitlements (-allowProvisioningUpdates registers the device and the App ID).
"""
import argparse, hashlib, json, os, plistlib, re, shutil, stat, subprocess, sys, tempfile, zipfile
from datetime import timezone
from pathlib import Path
from build_ipa import (pack_bytes, pack_file, pack_require, seed_pack_document,
                       verify_seed_pack, PACK_PART)

ENTITLEMENT = 'com.apple.developer.kernel.increased-memory-limit'
CACHE = Path.home()/'Library/Caches/MacNativeGames/ios-signing'

def run(cmd, **kw): return subprocess.run([str(x) for x in cmd], check=True, **kw)
def out(cmd): return subprocess.run([str(x) for x in cmd], check=True, capture_output=True, text=True).stdout

def teams():
    pems = out(['security','find-certificate','-a','-c','Apple Development','-p'])
    found = set()
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pems, re.S):
        subject = subprocess.run(['openssl','x509','-noout','-subject'], input=pem, capture_output=True, text=True).stdout
        if m := re.search(r'OU\s*=\s*([A-Z0-9]{10})', subject): found.add(m.group(1))
    return sorted(found)

def devices():
    with tempfile.NamedTemporaryFile(suffix='.json') as f:
        run(['xcrun','devicectl','list','devices','--json-output',f.name], capture_output=True)
        return [d for d in json.load(open(f.name))['result']['devices']
                if d.get('hardwareProperties',{}).get('platform') == 'iOS']

def pick_device(name):
    devs = devices()
    match = [d for d in devs if name in (d['deviceProperties'].get('name'), d['identifier'], d['hardwareProperties'].get('udid'))] if name else devs
    if len(match) != 1:
        listed = '\n'.join(f"  {d['deviceProperties'].get('name')} ({d['hardwareProperties'].get('marketingName')})" for d in devs)
        sys.exit(f"choose the device with --device <name>:\n{listed}" if devs else 'no paired iPhone / iPad found: connect it with a cable and trust this Mac')
    return match[0]

def profile(team, bundle_id, udid):
    """Build an empty app with the game's bundle identifier and entitlements; Xcode makes the profile for it."""
    proj = CACHE/bundle_id; proj.mkdir(parents=True, exist_ok=True)
    (proj/'main.m').write_text('int main(void) { return 0; }\n')
    (proj/'TOTK.entitlements').write_bytes(plistlib.dumps({ENTITLEMENT: True}))
    (proj/'project.yml').write_text(f'''name: TOTKSigning
options: {{deploymentTarget: {{iOS: "26.0"}}}}
targets:
  TOTK:
    type: application
    platform: iOS
    sources: [main.m]
    settings:
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}
      DEVELOPMENT_TEAM: {team}
      CODE_SIGN_STYLE: Automatic
      CODE_SIGN_ENTITLEMENTS: TOTK.entitlements
''')
    run(['xcodegen','generate','--quiet'], cwd=proj)
    derived = proj/'derived'
    log = proj/'xcodebuild.log'
    with log.open('w') as f:
        r = subprocess.run(['xcodebuild','-project','TOTKSigning.xcodeproj','-scheme','TOTK','-configuration','Debug',
                            '-destination',f'id={udid}','-derivedDataPath',str(derived),
                            '-allowProvisioningUpdates','-allowProvisioningDeviceRegistration','build'],
                           cwd=proj, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        errors = [l for l in log.read_text(errors='replace').splitlines() if 'error:' in l]
        sys.exit('Xcode could not make a provisioning profile:\n' + '\n'.join(errors[-8:]) + f'\nfull log: {log}')
    app = derived/'Build/Products/Debug-iphoneos/TOTK.app'
    return app/'embedded.mobileprovision', app

def identity_of(signed_app):
    """The SHA-1 of the certificate Xcode signed the empty app with: the same identity signs the game."""
    with tempfile.TemporaryDirectory() as d:
        run(['codesign','-d','--extract-certificates='+d+'/cert','-v',signed_app], capture_output=True)
        der = Path(d+'/cert0').read_bytes()
    return hashlib.sha1(der).hexdigest().upper()

PART = 1 << 30
def file_sha256(path):
    """Stable bounded content identity, never an mtime-only reuse checkpoint."""
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('linked input refused')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 64 << 30:
            raise ValueError('input is not a bounded regular file')
        sha = hashlib.sha256(); total = 0
        while block := os.read(fd, 1 << 20):
            total += len(block); sha.update(block)
            if total > before.st_size: raise ValueError('input grew during read')
        after = os.fstat(fd)
        if total != before.st_size or any(getattr(before, key) != getattr(after, key) for key in
                ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')):
            raise ValueError('input changed during read')
        return sha.hexdigest()
    finally:
        os.close(fd)

def device_files(dev, bundle_id, sub):
    """Empty only when a successful parent listing proves the child absent."""
    with tempfile.NamedTemporaryFile(suffix='.json') as f:
        r = subprocess.run(['xcrun','devicectl','device','info','files','--device',dev,'--domain-type','appDataContainer',
                            '--domain-identifier',bundle_id,'--subdirectory',sub,'--json-output',f.name], capture_output=True)
        if r.returncode:
            if sub != 'Documents':
                parent = str(Path(sub).parent)
                if parent != '.' and Path(sub).name not in device_files(dev, bundle_id, parent):
                    return {}
                sys.exit('cannot inspect an existing app data directory; no upload was started')
            sys.exit('cannot read app Documents on the device; connect and unlock it before retrying')
        document = json.load(open(f.name))
        result = document.get('result') if isinstance(document, dict) else None
        files = result.get('files') if isinstance(result, dict) else None
        if not isinstance(files, list) or any(not isinstance(item, dict) or
                not isinstance(item.get('relativePath', item.get('name')), str) or
                not Path(item.get('relativePath', item.get('name'))).name for item in files):
            sys.exit('invalid device directory listing; no upload was started')
    return {Path(x.get('relativePath', x.get('name', ''))).name: x.get('metadata', {}).get('size', 0) for x in files}   # devicectl's JSON

def push_game_data(dev, bundle_id, image):
    """The RomFS image into Documents/GameData as romfs.bin.000, .001, ... (ios/Sources/main.m reads it there), then
    romfs.sha256 naming it, so the next install skips it."""
    sha = json.loads((image.parent/'index.json').read_text())['romfs_sha256']
    if not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha) or file_sha256(image) != sha:
        raise ValueError('local RomFS does not match its extraction fingerprint')
    size = image.stat().st_size; parts = (size + PART - 1) // PART
    have = device_files(dev, bundle_id, 'Documents/GameData')
    expected_parts = {f'romfs.bin.{i:03d}' for i in range(parts)}
    existing_parts = {name for name in have if re.fullmatch(r'romfs\.bin\.[0-9]+', name)}
    if 'romfs.bin' in have or existing_parts - expected_parts:
        raise ValueError('existing device image layout needs explicit migration; no files were replaced')
    if have.get('romfs.sha256') == 64 + 1 and all(
            have.get(f'romfs.bin.{i:03d}') == min(PART, size - i * PART) for i in range(parts)):
        with tempfile.TemporaryDirectory() as d:
            got = Path(d)/'romfs.sha256'
            r = subprocess.run(['xcrun','devicectl','device','copy','from','--device',dev,'--domain-type','appDataContainer',
                                '--domain-identifier',bundle_id,'--source','Documents/GameData/romfs.sha256','--destination',got], capture_output=True)
            if r.returncode == 0 and got.read_text().strip() == sha:
                # The marker binds the intended source, not the current bytes.
                # Re-read every part before reuse; never repair a stale marker
                # merely because old/new pieces happen to have equal lengths.
                remote_sha = hashlib.sha256(); complete = True
                for i in range(parts):
                    piece = Path(d)/'verify-part'
                    piece.unlink(missing_ok=True)
                    r = subprocess.run(['xcrun','devicectl','device','copy','from','--device',dev,
                        '--domain-type','appDataContainer','--domain-identifier',bundle_id,
                        '--source',f'Documents/GameData/romfs.bin.{i:03d}','--destination',piece], capture_output=True)
                    expected = min(PART, size - i * PART)
                    if r.returncode or not piece.is_file() or piece.stat().st_size != expected:
                        complete = False; break
                    with piece.open('rb') as stream:
                        while block := stream.read(1 << 20): remote_sha.update(block)
                    piece.unlink()
                if complete and remote_sha.hexdigest() == sha:
                    print('game data: verified the device already has this image'); return
    print(f'game data: copying {size / 2**30:.1f} GiB in {parts} parts (once; later installs keep it)')
    with tempfile.TemporaryDirectory() as d, open(image, 'rb') as src:
        sent_sha = hashlib.sha256()
        def copy(local, name):
            run(['xcrun','devicectl','device','copy','to','--device',dev,'--domain-type','appDataContainer','--domain-identifier',
                 bundle_id,'--source',local,'--destination',f'Documents/GameData/{name}'], capture_output=True)
        (Path(d)/'romfs.sha256').write_text('stale\n'); copy(Path(d)/'romfs.sha256', 'romfs.sha256')   # until every part is there
        for i in range(parts):
            part = Path(d)/f'romfs.bin.{i:03d}'
            block = src.read(min(PART, size - i * PART))
            if len(block) != min(PART, size - i * PART): raise ValueError('local RomFS changed during transfer')
            sent_sha.update(block)
            part.write_bytes(block); copy(part, part.name); part.unlink()
            print(f'  part {i + 1}/{parts}', flush=True)
        if src.read(1) or sent_sha.hexdigest() != sha: raise ValueError('local RomFS changed during transfer')
        (Path(d)/'romfs.sha256').write_text(sha + '\n'); copy(Path(d)/'romfs.sha256', 'romfs.sha256')

def push_seed_pack(dev, bundle_id, folder, raw):
    """Only signed-bundle inventory selects the fixed Documents input path."""
    document=verify_seed_pack(folder,raw)
    sub='Documents/GameData/shader-packs/'+document['streamSHA256']+'/parts'
    expected={f'{part["index"]:03d}' for part in document['parts']}
    have=device_files(dev,bundle_id,sub)
    pack_require(not set(have)-expected,'unexpected device shader pack entries; no upload started')
    with tempfile.TemporaryDirectory(prefix='totk-seed-upload-') as directory:
        temporary=Path(directory).resolve()
        def remote_matches(part):
            name=f'{part["index"]:03d}';local=temporary/'readback'
            local.unlink(missing_ok=True)
            result=subprocess.run(['xcrun','devicectl','device','copy','from','--device',dev,
                '--domain-type','appDataContainer','--domain-identifier',bundle_id,
                '--source',sub+'/'+name,'--destination',local],capture_output=True)
            pack_require(result.returncode==0,'cannot verify an existing device shader pack piece')
            sha,size=pack_file(local,limit=PACK_PART)
            local.unlink()
            return sha==part['sha256'] and size==part['size']
        for part in document['parts']:
            name=f'{part["index"]:03d}'
            if name in have and remote_matches(part): continue
            local=temporary/'upload'
            local.unlink(missing_ok=True)
            # devicectl consumes this owned snapshot, never a previously hashed
            # mutable sidecar path. Copy and hash the same descriptor stream.
            with local.open('xb') as output:
                sha,size=pack_file(folder/'parts'/name,output.write,PACK_PART)
                output.flush();os.fsync(output.fileno())
            pack_require(sha==part['sha256'] and size==part['size'],'local shader pack piece changed')
            run(['xcrun','devicectl','device','copy','to','--device',dev,
                '--domain-type','appDataContainer','--domain-identifier',bundle_id,
                '--source',local,'--destination',sub+'/'+name],capture_output=True)
            local.unlink()
            pack_require(remote_matches(part),'uploaded shader pack piece failed readback')
        pack_require(set(device_files(dev,bundle_id,sub))==expected,'incomplete device shader pack inventory')
    print('shaders: verified every device pack piece; the app verifies and publishes its private seed')

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('ipa', type=Path, help='the unsigned IPA (or .app folder) from build_app.py --platform ios')
    ap.add_argument('--device', help='device name (as in Finder) or identifier; needed when several are paired')
    ap.add_argument('--team', help='Apple team ID (default: the only team with an Apple Development certificate)')
    ap.add_argument('--bundle-id', help='default: org.macnativegames.totk.<team>, so it is free to register on your team')
    ap.add_argument('--game-data', type=Path, help='romfs.bin (index.json beside it) for an IPA built with --ios-game-data documents')
    a = ap.parse_args()
    team = a.team or (lambda t: t[0] if len(t) == 1 else sys.exit(
        f'choose the team with --team: {", ".join(t)}' if t else 'no Apple Development certificate: add your Apple ID in Xcode > Settings > Accounts'))(teams())
    bundle_id = a.bundle_id or f'org.macnativegames.totk.{team.lower()}'
    dev = pick_device(a.device)
    udid = dev['hardwareProperties']['udid']
    print(f"team {team}, bundle {bundle_id}, device {dev['deviceProperties'].get('name')} ({udid})")

    print('provisioning profile: asking Xcode')
    prov, signed = profile(team, bundle_id, udid)
    info = plistlib.loads(out(['security','cms','-D','-i',prov]).encode())
    ents = info['Entitlements']
    if not ents.get(ENTITLEMENT):
        print(f'warning: your team cannot grant {ENTITLEMENT}; iOS may close the game when it runs out of memory')
    expires = info['ExpirationDate'].replace(tzinfo=timezone.utc).astimezone()  # plistlib returns naive UTC
    print(f"provisioning profile valid until {expires:%Y-%m-%d %H:%M} local time (run this again before then)")

    # Unpack once per IPA; later runs only re-sign. 16 GiB of game data is signed in place.
    work = a.ipa.with_suffix('.signed'); stamp = work/'.ipa-sha256'
    app = work/'Payload/TOTK.app'
    if a.ipa.is_dir():   # explicit installer mutates/signs this user-selected build output in place
        app = a.ipa.resolve(); work.mkdir(exist_ok=True)
    else:
        archive_sha = file_sha256(a.ipa)
        if not stamp.is_file() or stamp.read_text() != archive_sha or not app.is_dir():
            print(f'unpacking {a.ipa.name}')
            shutil.rmtree(work, ignore_errors=True); work.mkdir()
            run(['ditto','-x','-k',a.ipa,work])
            if file_sha256(a.ipa) != archive_sha: raise ValueError('IPA changed during extraction')
            stamp.write_text(archive_sha)
    pack_metadata=app/'GameData/shader-seed-pack.json';pack_raw=None;pack_folder=None
    if pack_metadata.exists():
        pack_raw=pack_bytes(pack_metadata);pack_document=seed_pack_document(pack_raw)
        bundled=plistlib.loads(pack_bytes(app/'Info.plist'))
        pack_require(type(bundled.get('TOTKShaderSeedPackReaderABI')) is int and
            bundled['TOTKShaderSeedPackReaderABI']==1,'shader pack requires actual reader ABI1')
        pack_require(bundled.get('TOTKShaderSeedPackMetadataSHA256')==hashlib.sha256(pack_raw).hexdigest(),
                     'bundled shader pack metadata pin differs')
        for field,key in (('titleID','TOTKShaderSeedPackTitleID'),('titleVersion','TOTKShaderSeedPackTitleVersion'),
                ('sourceRomFSSHA256','TOTKShaderSeedPackRomFSSHA256'),('chain','TOTKShaderSeedPackChain')):
            pack_require(type(bundled.get(key)) is type(pack_document[field]) and
                bundled[key]==pack_document[field],'bundled shader pack identity differs')
        pack_folder=a.ipa.with_name(a.ipa.stem+'-shader-pack')/pack_document['streamSHA256']
        verify_seed_pack(pack_folder,pack_raw)
    plist = app/'Info.plist'
    infoplist = plistlib.loads(plist.read_bytes()); infoplist['CFBundleIdentifier'] = bundle_id
    plist.write_bytes(plistlib.dumps(infoplist, fmt=plistlib.FMT_BINARY))
    shutil.copy2(prov, app/'embedded.mobileprovision')
    entfile = work/'entitlements.plist'
    entfile.write_bytes(plistlib.dumps({k: ents[k] for k in ('application-identifier','com.apple.developer.team-identifier',
                                                                'get-task-allow', ENTITLEMENT) if k in ents}))
    print('signing (a few minutes: every game file is hashed)')
    run(['codesign','--force','--sign',identity_of(signed),'--entitlements',entfile,'--generate-entitlement-der',app])
    if pack_raw is not None:
        pack_require(pack_bytes(pack_metadata)==pack_raw,'shader metadata changed during signing')
    print('installing (a few minutes over the cable)')
    run(['xcrun','devicectl','device','install','app','--device',dev['identifier'],app])
    if a.game_data: push_game_data(dev['identifier'], bundle_id, a.game_data)
    if pack_raw is not None: push_seed_pack(dev['identifier'],bundle_id,pack_folder,pack_raw)
    print('installed. First time on this device: Settings > General > VPN & Device Management > trust your Apple ID.')

if __name__ == '__main__': main()
