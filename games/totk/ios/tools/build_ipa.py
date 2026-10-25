#!/usr/bin/env python3
"""Build an unsigned, sideloadable iPhone/iPad IPA from a prepared TOTK work tree."""
import argparse, hashlib, json, os, plistlib, re, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
from compile_seed import METAL_FLAGS
from xcode_dir import developer_dir

PACK_PART = 1 << 30
PACK_TOTAL = 16 << 30
PACK_FILE = 64 << 20
PACK_COUNT = 262144

def pack_require(condition, message):
    if not condition: raise RuntimeError(message)

def pack_file(path, consume=None, limit=PACK_FILE):
    """Hash exactly the stable, unlinked bytes optionally consumed by the writer."""
    path=Path(path)
    pack_require(not any(p.is_symlink() for p in (path,*path.parents)), 'linked shader pack input')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        pack_require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and
                     0<=before.st_size<=limit,'invalid shader pack file')
        sha=hashlib.sha256();total=0
        while block:=os.read(fd,65536):
            total+=len(block)
            pack_require(total<=before.st_size,'shader pack input grew')
            sha.update(block)
            if consume is not None: consume(block)
        after=os.fstat(fd)
        pack_require(total==before.st_size and all(getattr(before,k)==getattr(after,k) for k in
                     ('st_dev','st_ino','st_mode','st_nlink','st_size','st_mtime_ns','st_ctime_ns')),
                     'shader pack input changed')
        return sha.hexdigest(),total
    finally: os.close(fd)

def pack_bytes(path, limit=PACK_FILE):
    blocks=[];pack_file(path,blocks.append,limit);return b''.join(blocks)

def pack_json(raw):
    pack_require(len(raw)<=PACK_FILE,'shader pack metadata too large')
    def unique(pairs):
        result={}
        for key,value in pairs:
            pack_require(key not in result,'duplicate shader pack JSON field');result[key]=value
        return result
    return json.loads(raw,object_pairs_hook=unique,
                      parse_constant=lambda value: pack_require(False,'nonfinite shader pack JSON'))

def pack_name(name):
    return isinstance(name,str) and re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,126}',name) is not None

def pack_entries(folder, limit):
    names=set()
    with os.scandir(folder) as entries:
        for entry in entries:
            pack_require(len(names)<limit,'shader pack directory exceeds count limit')
            names.add(entry.name)
    return names

def seed_pack_document(raw):
    """Strict shared producer/installer schema; no external path fields exist."""
    document=pack_json(raw)
    pack_require(isinstance(document,dict) and set(document)=={
        'schema','format','titleID','titleVersion','sourceRomFSSHA256','chain','manifestSHA256',
        'streamSHA256','streamSize','partSize','parts','members'},'invalid shader pack fields')
    def integer(value,low,high): return type(value) is int and low<=value<=high
    def sha(value): return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None
    pack_require(type(document['schema']) is int and document['schema']==1 and
        document['format']=='TOTKPACK1' and isinstance(document['titleID'],str) and
        re.fullmatch('[0-9a-f]{16}',document['titleID']) is not None and document['titleID']!='0'*16 and
        integer(document['titleVersion'],0,0xffffffff) and sha(document['sourceRomFSSHA256']) and
        isinstance(document['chain'],str) and re.fullmatch('[ -~]{1,128}',document['chain']) is not None and
        sha(document['manifestSHA256']) and sha(document['streamSHA256']) and
        integer(document['streamSize'],11,PACK_TOTAL) and
        type(document['partSize']) is int and document['partSize']==PACK_PART,
        'invalid shader pack identity or limits')
    parts=document['parts'];members=document['members']
    pack_require(isinstance(parts,list) and len(parts)==(document['streamSize']+PACK_PART-1)//PACK_PART and
        1<=len(parts)<=16 and isinstance(members,list) and 2<=len(members)<=PACK_COUNT,'invalid shader pack counts')
    for i,part in enumerate(parts):
        pack_require(isinstance(part,dict) and set(part)=={'index','size','sha256'} and
            type(part['index']) is int and part['index']==i and
            integer(part['size'],1,PACK_PART) and part['size']==min(PACK_PART,document['streamSize']-i*PACK_PART) and
            sha(part['sha256']),'invalid shader pack part')
    previous='';folded=set();manifest=None;has_map=False;stream_size=11
    for member in members:
        pack_require(isinstance(member,dict) and set(member)=={'name','size','sha256'} and
            pack_name(member['name']) and member['name']>previous and member['name'].lower() not in folded and
            integer(member['size'],0,PACK_FILE) and sha(member['sha256']),'invalid shader pack member')
        previous=member['name'];folded.add(previous.lower())
        stream_size+=2+len(previous)+8+member['size']
        pack_require(stream_size<=PACK_TOTAL,'shader pack stream exceeds quota')
        if previous=='seed-manifest.json': manifest=member['sha256']
        if previous=='shader_map.tsv': has_map=True
    pack_require(manifest==document['manifestSHA256'] and has_map and stream_size==document['streamSize'],
                 'shader pack inventory does not bind its manifest/map/stream')
    return document

def verify_seed_pack(folder, raw):
    document=seed_pack_document(raw);folder=Path(folder)
    pack_require(not folder.is_symlink() and folder.is_dir() and
        pack_entries(folder,2)=={'parts','shader-seed-pack.json'} and
        pack_bytes(folder/'shader-seed-pack.json')==raw,'shader pack sidecar differs from bundled metadata')
    parts=folder/'parts'
    pack_require(not parts.is_symlink() and parts.is_dir() and
        pack_entries(parts,16)=={f'{i:03d}' for i in range(len(document['parts']))},
        'shader pack sidecar part inventory differs')
    stream=hashlib.sha256()
    for part in document['parts']:
        digest,size=pack_file(parts/f'{part["index"]:03d}',stream.update,PACK_PART)
        pack_require(digest==part['sha256'] and size==part['size'],'shader pack piece hash differs')
    pack_require(stream.hexdigest()==document['streamSHA256'],'shader pack stream hash differs')
    return document

def make_seed_pack(seed, sidecar, identity):
    """Emit exact original TOTKPACK1 bytes; publish only a fully hashed sidecar."""
    seed=Path(seed);sidecar=Path(sidecar)
    pack_require(not seed.is_symlink() and seed.is_dir(),'invalid shader seed directory')
    names=[];folded=set()
    with os.scandir(seed) as entries:
        for entry in entries:
            pack_require(len(names)<PACK_COUNT and pack_name(entry.name) and
                entry.name.lower() not in folded and entry.is_file(follow_symlinks=False),'invalid shader seed inventory')
            names.append(entry.name);folded.add(entry.name.lower())
    names.sort()
    pack_require('seed-manifest.json' in names and 'shader_map.tsv' in names,'shader seed manifest/map missing')
    manifest_raw=pack_bytes(seed/'seed-manifest.json');manifest_document=pack_json(manifest_raw)
    pack_require(isinstance(manifest_document,dict) and manifest_document.get('chain')==identity['chain'] and
        manifest_document.get('source_romfs_sha256')==identity['sourceRomFSSHA256'] and
        isinstance(manifest_document.get('files'),dict) and manifest_document['files'],
        'shader seed manifest differs from selected source/chain')
    pack_require(not any(p.is_symlink() for p in (sidecar,*sidecar.parents)),'linked shader sidecar directory')
    sidecar.mkdir(parents=True,exist_ok=True,mode=0o700)
    stage=Path(tempfile.mkdtemp(prefix='.seed-pack-stage-',dir=sidecar));(stage/'parts').mkdir(mode=0o700)
    output=None;part_hash=None;part_bytes=0;total=0;stream=hashlib.sha256();parts=[];members=[]
    def close_part():
        nonlocal output
        if output is not None:
            output.flush();os.fsync(output.fileno());output.close();output=None
            parts.append({'index':len(parts),'size':part_bytes,'sha256':part_hash.hexdigest()})
    def write(block):
        nonlocal output,part_hash,part_bytes,total
        at=0
        while at<len(block):
            if output is None or part_bytes==PACK_PART:
                close_part();pack_require(len(parts)<16,'too many shader pack parts')
                output=(stage/'parts'/f'{len(parts):03d}').open('xb');part_hash=hashlib.sha256();part_bytes=0
            count=min(len(block)-at,PACK_PART-part_bytes)
            pack_require(total+count<=PACK_TOTAL,'shader pack exceeds stream quota')
            chunk=block[at:at+count];output.write(chunk);part_hash.update(chunk);stream.update(chunk)
            part_bytes+=count;total+=count;at+=count
    try:
        write(b'TOTKPACK1')
        for name in names:
            # First read fixes length/hash; the actual emitted read must match.
            expected,size=pack_file(seed/name)
            write(len(name).to_bytes(2,'little')+name.encode('ascii')+size.to_bytes(8,'little'))
            actual,actual_size=pack_file(seed/name,write)
            pack_require(actual==expected and actual_size==size,'shader seed changed between reads')
            members.append({'name':name,'size':size,'sha256':actual})
        pack_require(set(names)==pack_entries(seed,PACK_COUNT),'shader seed inventory changed')
        write(b'\0\0');close_part()
        manifest=next(member['sha256'] for member in members if member['name']=='seed-manifest.json')
        pack_require(manifest==hashlib.sha256(manifest_raw).hexdigest(),'shader seed manifest changed')
        actual_members={member['name']:member['sha256'] for member in members}
        pack_require(all(pack_name(name) and actual_members.get(name)==sha
            for name,sha in manifest_document['files'].items()),'shader seed member differs from its manifest')
        document=dict(identity,schema=1,format='TOTKPACK1',manifestSHA256=manifest,
            streamSHA256=stream.hexdigest(),streamSize=total,partSize=PACK_PART,parts=parts,members=members)
        raw=(json.dumps(document,sort_keys=True,separators=(',',':'))+'\n').encode()
        seed_pack_document(raw)
        (stage/'shader-seed-pack.json').write_bytes(raw)
        verify_seed_pack(stage,raw)
        final=sidecar/document['streamSHA256']
        pack_require(not final.is_symlink(),'linked shader pack identity directory')
        if final.exists(): verify_seed_pack(final,raw)
        else: stage.rename(final)
        return raw
    finally:
        if output is not None: output.close()
        shutil.rmtree(stage,ignore_errors=True)

def seed_pack_identity(tree, version):
    manifests={'v0':'1.0.0','v112':'1.1.2','v121':'1.2.1','v143':'1.4.3'}
    expected=pack_json(pack_bytes(tree/'assets'/f'expected-v{manifests[version]}.json'))
    header=pack_bytes(tree/'third_party/d2r_gfx/gfx/nvn/dmsh_chain.h').decode('ascii')
    match=re.search(r'^#define DMSH_CHAIN "([ -~]{1,128})"$',header,re.M)
    pack_require(match is not None,'missing compiled shader chain')
    identity={'titleID':expected['title_id'].lower(),'titleVersion':expected['version'],
        'sourceRomFSSHA256':expected['romfs']['sha256'],'chain':match.group(1)}
    return identity,expected['display_version']

def require_seed_pack_reader(app, env):
    """Source/header markers alone cannot make a seedless app work."""
    info=plistlib.loads(pack_bytes(app/'Info.plist'))
    pack_require(type(info.get('TOTKShaderSeedPackReaderABI')) is int and
                 info['TOTKShaderSeedPackReaderABI']==1,'built app lacks seed pack reader ABI1')
    executable=info.get('CFBundleExecutable')
    pack_require(pack_name(executable),'invalid built app executable name')
    pack_file(app/executable,limit=512<<20)
    symbols=subprocess.run(['xcrun','nm','-gjU',str(app/executable)],env=env,
                           capture_output=True,text=True,check=True).stdout.splitlines()
    pack_require('_TOTKShaderPackReaderABI' in symbols,'built app lacks actual seed pack reader symbol')

def run(args, cwd, log, env):
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('w') as f:
        p=subprocess.run([str(x) for x in args],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
    if p.returncode:
        tail=log.read_text(errors='replace').splitlines()[-35:]
        raise RuntimeError(f"{args[0]} failed; see {log}\n"+'\n'.join(tail))

def clone(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True)
    if subprocess.run(['cp','-c',str(src),str(dst)],capture_output=True).returncode: shutil.copy2(src,dst)
def clone_folder(src,dst):
    """One APFS clone of a whole folder (macOS clonefile), as build_app.py copy_tree: the seed is ~100,000 files, which
    cp -cR clones one by one (minutes per copy, 2026-10-22)."""
    if sys.platform!='darwin': return False
    import ctypes
    libc=ctypes.CDLL(None);libc.clonefile.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint32]
    dst.parent.mkdir(parents=True,exist_ok=True)
    return libc.clonefile(os.fsencode(src),os.fsencode(dst),0)==0

def copy_tree(src,dst):
    src=Path(src);dst=Path(dst)
    if dst.exists(): shutil.rmtree(dst)
    if clone_folder(src,dst): return
    dst.mkdir(parents=True,exist_ok=True)
    if sys.platform=='darwin':
        result=subprocess.run(['/bin/cp','-cR',str(src)+os.sep+'.',str(dst)],capture_output=True)
        if result.returncode==0: return
        shutil.rmtree(dst);dst.mkdir(parents=True,exist_ok=True)
    for p in src.rglob('*'):
        if p.is_file(): clone(p,dst/p.relative_to(src))

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--tree',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--version',choices=['v0','v112','v121','v143'],required=True);p.add_argument('--logs',type=Path,required=True)
    p.add_argument('--display-settings',action='store_true',help='experimental v143 signed720/1080 scene/output and full-aspect profile')
    p.add_argument('--seed-pack',action='store_true',help='opt-in verified Documents shader pack; requires --image-outside and a wired ABI1 reader')
    p.add_argument('--image-outside',action='store_true',help='leave romfs.bin out: the device keeps it in Documents/GameData');p.add_argument('--app-name',default='Tears of the Kingdom');p.add_argument('--bundle-id',default='org.macnativegames.totk')
    a=p.parse_args(); tree=a.tree.resolve(); ios=tree/'ios';gen=ios/'Gen';logs=a.logs.resolve(); out=a.out.resolve()
    if a.display_settings and a.version!='v143': raise RuntimeError('--display-settings supports only TOTK1.4.3')
    if a.seed_pack and not a.image_outside: raise RuntimeError('--seed-pack requires --image-outside')
    if out.suffix.lower() not in ('.ipa','.app'): raise RuntimeError('iOS output path must end in .ipa (or .app: the unsigned folder)')
    env=dict(os.environ,DEVELOPER_DIR=developer_dir())
    sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],env=env,text=True).strip()
    subprocess.run(['xcodebuild','-version'],env=env,check=True,stdout=subprocess.DEVNULL)
    if not shutil.which('xcodegen'): raise RuntimeError('install xcodegen: brew install xcodegen')
    gen.mkdir(parents=True,exist_ok=True)
    version_dir=tree/'build'/({'v0':'','v112':'v112','v121':'v121','v143':'v143'}[a.version])
    if a.version=='v0': version_dir=tree/'build'
    for name in ('runtime_tables.h','romfs_config.h'):
        clone(version_dir/name,gen/name)
    clone(tree/'build/shared_fonts_config.h',gen/'shared_fonts_config.h')
    # Export the final code after all verified runtime patches have been applied, then embed it in executable segments.
    host=tree/('build/totk-native' if a.version=='v0' else f'build/totk-native-{a.version}')
    rewritten=tree/f'rewritten/{a.version}'; modules=gen/'modules';modules.mkdir(exist_ok=True)
    e=dict(env,TOTK_EXPORT_IOS=str(modules))
    e.pop('TOTK_IOS_DISPLAY_SETTINGS',None)   # This signed-code capability belongs to the explicit build flag.
    e.pop('TOTK_IOS_ASPECT_VERT',None)
    if a.display_settings:
        # Patch only the verified host image before gen_embed seals its executable-section hashes.
        e.update(TOTK_IOS_DISPLAY_SETTINGS='1',TOTK_RENDER_RES='1280x720',TOTK_OUTPUT_RES='1280x720',
                 TOTK_FIXED_RES='1',TOTK_ASPECT='0',TOTK_ASPECT_VERT='1',TOTK_IOS_ASPECT_VERT='1')
    run([host,rewritten,'export-ios'],tree,logs/'export-ios.log',e)
    flags=subprocess.check_output([sys.executable,ios/'tools/gen_embed.py',rewritten,gen/'embed.S','--text-dir',modules,'main','subsdk0','sdk'],text=True,env=env).strip()
    # The app's sources use version-specific patch and generated runtime tables.
    project=(ios/'project.yml').read_text()
    if a.version=='v143': project=project.replace('          - loader.c','          - loader.c\n          - game_patches.c')
    else: project=project.replace('          - loader.c','          - loader.c\n          - game_patches_v143.c')
    if a.version!='v0': project=project.replace('-I../build\n','-I../build -DTOTK_GAME_'+a.version.upper()+'=1\n')
    if a.display_settings:
        if project.count('-DTOTK_GAME_V143=1\n')!=1 or project.count('        MetalHudEnabled: true\n')!=1:
            raise RuntimeError('cannot bind the signed display profile to this iOS project')
        project=project.replace('-DTOTK_GAME_V143=1\n','-DTOTK_GAME_V143=1 -DTOTK_IOS_DISPLAY_SETTINGS=1 -DTOTK_IOS_ASPECT_VERT=1\n')
        project=project.replace('        MetalHudEnabled: true\n',
                                '        MetalHudEnabled: true\n        TOTKIOSDisplaySettingsVersion: 1\n        TOTKIOSFourThreeLayoutVersion: 1\n')
    # The home screen icon: the game's own, which the build took from its control data for the Mac app
    # (build/AppIcon.icns, scripts/extract_app_icon.py), as a single-size asset catalog. Without it the app had none.
    icon=tree/'build/AppIcon.icns'; catalog=gen/'Assets.xcassets'; shutil.rmtree(catalog,ignore_errors=True)
    if icon.is_file():
        appicon=catalog/'AppIcon.appiconset'; appicon.mkdir(parents=True)
        (catalog/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
        run(['sips','-s','format','png','-z','1024','1024',icon,'--out',appicon/'icon-1024.png'],tree,logs/'ios-icon.log',env)
        (appicon/'Contents.json').write_text(json.dumps({'images':[{'filename':'icon-1024.png','idiom':'universal','platform':'ios','size':'1024x1024'}],
                                                         'info':{'author':'xcode','version':1}}))
        project=project.replace('      - path: Gen/embed.S\n','      - path: Gen/embed.S\n      - path: Gen/Assets.xcassets\n')
        project=project.replace('      CODE_SIGN_STYLE: Manual\n','      CODE_SIGN_STYLE: Manual\n      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n')
    (ios/'project.generated.yml').write_text(project)
    # Build device dependencies separately: Homebrew's Mac archives cannot be linked into an iOS application.
    deps=tree/'build/ios-deps'
    run([sys.executable,ios/'tools/build_deps.py',deps],tree,logs/'ios-dependencies.log',env)
    shutil.copytree(deps/'include',gen/'deps/include',dirs_exist_ok=True)
    (gen/'deps/lib').mkdir(parents=True,exist_ok=True)
    for lib in ('libopus.a','libvpx.a'): clone(deps/'lib'/lib,gen/'deps/lib'/lib)
    seed_src=tree/f'build/shader-seed/{a.version}'; seed=gen/'totk/shader-seed'
    if not (seed_src/'seed-manifest.json').is_file(): raise RuntimeError(f'missing verified shader seed: {seed_src}')
    import hashlib
    source_manifest_hash=hashlib.sha256((seed_src/'seed-manifest.json').read_bytes()).hexdigest()
    expected_metallibs=sum(name.endswith('_b.metal') for name in json.loads((seed_src/'seed-manifest.json').read_text())['files'])
    cached_manifest=seed/'seed-manifest.json'
    reuse_seed=False
    if cached_manifest.is_file():
        cached=json.loads(cached_manifest.read_text())
        reuse_seed=(cached.get('ios_source_manifest_sha256')==source_manifest_hash and
                    cached.get('ios_metallibs')==expected_metallibs and
                    cached.get('ios_metal_flags')==' '.join(METAL_FLAGS) and   # e.g. not the old fast-math libraries
                    all((seed/(name.removesuffix('.metal')+'.metallib')).is_file()
                        for name in json.loads((seed_src/'seed-manifest.json').read_text())['files'] if name.endswith('_b.metal')))
    if not reuse_seed:
        if seed.exists(): shutil.rmtree(seed)
        copy_tree(seed_src,seed)
        run([sys.executable,ios/'tools/compile_seed.py',seed,'iphoneos'],tree,logs/'ios-shaders.log',env)
    seed_manifest=json.loads((seed/'seed-manifest.json').read_text())
    seed_manifest['ios_source_manifest_sha256']=source_manifest_hash
    (seed/'seed-manifest.json').write_text(json.dumps(seed_manifest,indent=2)+'\n')
    (seed/'shader_map.tsv').write_text('# TOTK control-code-sha256-v1\n')
    # The file list: every shader file with its SHA-256. Hashes the manifest already has are kept (the seed's own files,
    # checked when it was prepared, and the metallibs compile_seed.py hashed); only a file it lacks is read, so a build
    # whose seed did not change hashes nothing (all ~100,000 files were read again in each build, 2026-10-22).
    # shader_map.tsv is read in place (DM_NVN_SHMAP); the importer accepts only shader files, so it stays out of the list.
    manifest=json.loads((seed/'seed-manifest.json').read_text()); known=manifest.get('files',{})
    names=sorted(n for n in os.listdir(seed) if n not in ('seed-manifest.json','shader_map.tsv') and (seed/n).is_file())
    manifest['files']={n:known.get(n) or hashlib.sha256((seed/n).read_bytes()).hexdigest() for n in names}
    (seed/'seed-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    # Generate the app project with resolved identity and the embedded-segment linker flags.
    env.update(TOTK_APP_NAME=a.app_name,TOTK_BUNDLE_ID=a.bundle_id)
    xcconfig=gen/'totk.xcconfig'
    frameworks=' '.join('-framework '+x for x in ['UIKit','Metal','MetalFX','Foundation','QuartzCore','ImageIO','CoreGraphics','CoreText','UniformTypeIdentifiers','CoreFoundation','AudioToolbox','GameController','AVFAudio','Security','WebKit'])
    xcconfig.write_text(f'OTHER_LDFLAGS = $(inherited) {frameworks} Gen/deps/lib/libopus.a Gen/deps/lib/libvpx.a {flags}\n')
    run(['xcodegen','generate','--spec','project.generated.yml'],ios,logs/'xcodegen.log',env)
    derived=tree/'build/ios-derived';run(['xcodebuild','-project','TOTKIOS.xcodeproj','-scheme','TOTKIOS','-configuration','Release',
        '-destination','generic/platform=iOS','-derivedDataPath',derived,'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY='],
        ios,logs/'xcodebuild-ios.log',env)
    app=derived/'Build/Products/Release-iphoneos/TOTK.app'
    if not app.is_dir(): raise RuntimeError(f'Xcode did not produce {app}')
    if a.seed_pack: require_seed_pack_reader(app,env)
    # Carry the increased-memory-limit entitlement in the executable's ad-hoc signature so re-signing tools keep it;
    # the game's 3.2 GiB pool exceeds the default iOS footprint limit.
    run(['codesign','--force','--sign','-','--entitlements',ios/'Sources/TOTK.entitlements',app/'TOTK'],ios,logs/'ios-entitlements.log',env)
    # Keep the Xcode product small. Assemble GameData only in the final output,
    # avoiding product -> Payload -> output copies of the complete private seed.
    dest=out if out.suffix=='.app' else tree/'build/ios-payload/Payload/TOTK.app'
    if dest==app or dest.is_relative_to(app): raise RuntimeError('output overlaps the Xcode product')
    if (app/'GameData').exists(): shutil.rmtree(app/'GameData')  # old packaging left data in the product
    if out.suffix!='.app': shutil.rmtree(tree/'build/ios-payload',ignore_errors=True)
    copy_tree(app,dest)
    res=dest/'GameData';res.mkdir(exist_ok=True)
    romfs=tree/f'extracted/{a.version}/romfs'
    copy_tree(romfs,res/'romfs')
    if a.image_outside:   # the index stays (it changes with the build); the 17 GB image is in Documents/GameData (main.m)
        for p in list((res/'romfs').glob('romfs.bin*')): p.unlink()
    for src,dst in [(tree/f'extracted/{a.version}/romfs-patches',res/'romfs-patches'),
                    (tree/f'extracted/{a.version}/romfs-patches-out',res/'romfs-patches-out'),
                    (tree/'extracted/firmware/shared-fonts',res/'shared-fonts')]: copy_tree(src,dst)
    tall = res/'romfs-patches-4x3'
    if tall.exists(): shutil.rmtree(tall)
    if a.display_settings:
        # Regenerate from the verified original image. The existing generator checks panes and emits the integrity manifest.
        run([sys.executable,tree/'scripts/make_romfs_patches.py','--version','v143','--aspect','1440x1080',
             '--output-dir',tall],tree,logs/'ios-layout-4x3.log',env)
    copy_tree(seed,res/'shader-seed')
    # The first frame waits only for the title screen's shaders (pso_title.tsv); the runtime looks for the list next to
    # DM_NVN_SHMAP, which is in shader-seed on iOS. Without it the first frame waits for the whole warm-up.
    # Exported from the one shared shader list (games/totk/assets/shader_list.tsv, docs/shader-list.md).
    # The list's other warm rows (its render pipelines) go in as pso_list.tsv: shader-seed/pso_manifest.tsv is the seed's own
    # list there, and the runtime reads both (nvn_mtl.m warm_start). Before 2026-10-22 they stayed in the build logs.
    run([sys.executable,tree/'scripts/shader_list.py','export',tree/'assets/shader_list.tsv',res/'shader-seed/pso_list.tsv',
         res/'shader-seed/pso_title.tsv'],tree,logs/'shader-list.log',env)
    aliases=seed_src.with_name(seed_src.name+'.aliases.tsv')   # listed variants the seed carries under another name
    if aliases.is_file():
        run([sys.executable,tree/'scripts/shader_list.py','rename',aliases,res/'shader-seed/pso_title.tsv',
             res/'shader-seed/pso_list.tsv'],tree,logs/'shader-list-rename.log',env)
    # Bind the actual final exported/renamed lists (and map) before taking a
    # transport or trusted-consumer raw-manifest pin. Previous approved pins
    # cannot authorize these changed bytes.
    final_seed=res/'shader-seed'
    previous_manifest=pack_bytes(final_seed/'seed-manifest.json')
    final_manifest=pack_json(previous_manifest)
    pack_require(isinstance(final_manifest,dict) and isinstance(final_manifest.get('files'),dict),
                 'invalid final shader seed manifest')
    pso_hashes={name:pack_file(final_seed/name)[0] for name in ('pso_list.tsv','pso_title.tsv')}
    final_manifest['files'].update(pso_hashes)
    final_manifest['shader_map_sha256']=pack_file(final_seed/'shader_map.tsv')[0]
    final_manifest_raw=(json.dumps(final_manifest,indent=2)+'\n').encode()
    (final_seed/'seed-manifest.json').write_bytes(final_manifest_raw)
    logs.mkdir(parents=True,exist_ok=True)
    (logs/'ios-final-seed-observation.json').write_text(json.dumps({
        'schema':1,'status':'source-prepared; no device acceptance',
        'previousManifestSHA256':hashlib.sha256(previous_manifest).hexdigest(),
        'manifestSHA256':hashlib.sha256(final_manifest_raw).hexdigest(),
        'shaderMapSHA256':final_manifest['shader_map_sha256'],'finalPSOLists':pso_hashes,
        'builderSHA256':pack_file(Path(__file__),limit=4<<20)[0]},indent=2)+'\n')
    if a.seed_pack:
        identity,game_version=seed_pack_identity(tree,a.version)
        raw=make_seed_pack(res/'shader-seed',out.with_name(out.stem+'-shader-pack'),identity)
        # App resources and these public identity facts are covered by the
        # explicit install tool's final developer signature, not an env marker.
        (res/'shader-seed-pack.json').write_bytes(raw)
        info=plistlib.loads((dest/'Info.plist').read_bytes())
        info.update(TOTKShaderSeedPackTitleID=identity['titleID'],
            TOTKShaderSeedPackTitleVersion=identity['titleVersion'],
            TOTKShaderSeedPackRomFSSHA256=identity['sourceRomFSSHA256'],
            TOTKShaderSeedPackGameVersion=game_version,TOTKShaderSeedPackChain=identity['chain'],
            TOTKShaderSeedPackMetadataSHA256=hashlib.sha256(raw).hexdigest())
        (dest/'Info.plist').write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
        shutil.rmtree(res/'shader-seed')
    # Keep the first install self-contained; Documents shader transport is not
    # enabled until producer/reader integrity and publication contracts exist.
    if out.suffix=='.app':
        print(f'app ready: {out}; unsigned, install it with ios/tools/install_device.py'); return
    payload=tree/'build/ios-payload'
    out.parent.mkdir(parents=True,exist_ok=True);out.unlink(missing_ok=True)
    run(['zip','-qry','-0',out,'Payload'],payload,logs/'ipa-zip.log',env)
    print(f'IPA ready: {out} ({out.stat().st_size/2**30:.1f} GiB); unsigned, sideload with your signing tool')

if __name__=='__main__':
    try: main()
    except (RuntimeError,subprocess.CalledProcessError,OSError) as e: print(f'ERROR: {e}',file=sys.stderr);sys.exit(1)
