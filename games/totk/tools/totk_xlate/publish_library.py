#!/usr/bin/env python3
"""Build real in-process Cross + patched NativeAOT library, with offline restore.

No SDK/package installation or source download. Supply the exact pinned public
SPIRV-Cross checkout. Missing already-cached .NET packages are a failed gate.
An ios-arm64 attempt is not evidence of supported NativeAOT until it succeeds.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
PIN='aa217aeb6c9f0ace7a0ab233b28807edf45eb165'
IOS_MIN='16.0'
CROSS_SOURCES=('spirv_cross.cpp','spirv_parser.cpp','spirv_cross_parsed_ir.cpp',
               'spirv_cfg.cpp','spirv_glsl.cpp','spirv_msl.cpp')


def checked_patches(root,folder):
    spec=importlib.util.spec_from_file_location('canopy_checked_patches',HERE/'checked_patches.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.apply_checked(root,folder)


def run(command,**kwargs):
    return subprocess.run([str(x) for x in command],check=True,**kwargs)


def capture(command):
    return subprocess.check_output(command,text=True).strip()


def validate_cross_source(source, pin=PIN):
    if capture(['git','-C',str(source),'rev-parse','HEAD'])!=pin:
        raise ValueError('SPIRV-Cross commit does not match repository pin')
    # Include ignored files: even an untracked/ignored header can affect -I.
    if capture(['git','-C',str(source),'status','--porcelain','--untracked-files=all','--ignored']):
        raise ValueError('SPIRV-Cross source must be entirely clean, including untracked and ignored files')


def file_records(folder):
    records={}
    for path in sorted(folder.rglob('*')):
        if path.is_symlink():raise ValueError('Symlink in build input/output tree')
        if path.is_file():records[path.relative_to(folder).as_posix()]={
            'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':path.stat().st_size}
        elif not path.is_dir():raise ValueError('Special file in build input/output tree')
    return records


def tree_digest(folder):
    # Length-framed canonical JSON records bind relative names, sizes and bytes.
    return hashlib.sha256(json.dumps(file_records(folder),sort_keys=True,separators=(',',':')).encode()).hexdigest()


def metadata():
    result={'schema':1,'dotnetAvailable':bool(shutil.which('dotnet')),
            'xcrunAvailable':bool(shutil.which('xcrun')),'compiler':None}
    compiler=shutil.which('c++')
    if compiler:result['compiler']=capture([compiler,'--version']).splitlines()[0]
    if result['dotnetAvailable']:
        result['dotnetVersion']=capture(['dotnet','--version'])
        result['dotnetSDKs']=capture(['dotnet','--list-sdks']).splitlines()
    if result['xcrunAvailable']:
        result['iphoneosSDK']=capture(['xcrun','--sdk','iphoneos','--show-sdk-version'])
    return result


def apple_flags(rid):
    """One target contract for Cross, NativeAOT and the final native consumer."""
    sdk='iphoneos' if rid=='ios-arm64' else 'iphonesimulator' if rid=='iossimulator-arm64' else 'macosx'
    flags=['-isysroot',capture(['xcrun','--sdk',sdk,'--show-sdk-path']),'-arch','arm64']
    if rid.startswith('ios'):
        flags+=['-target','arm64-apple-ios'+IOS_MIN+('-simulator' if rid.startswith('iossimulator') else '')]
    return sdk,flags


def read_link_plan(path):
    # This is trusted build-system output, never metadata from a shader job.
    # Reject shell operators anyway: arguments are executed without a shell.
    if path.stat().st_size>1024*1024:raise ValueError('Native link plan exceeds limit')
    arguments=[]
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if '\0' in line:raise ValueError('Invalid native link plan')
        arguments+=shlex.split(line)
    if not arguments:raise ValueError('NativeAOT emitted no native dependency plan')
    return arguments


def validate_apple_product(path,rid):
    """Inspect actual linked Mach-O; filenames/RIDs alone prove no target."""
    arch=capture(['xcrun','lipo','-archs',path])
    if arch!='arm64':raise ValueError('Native product architecture is not exclusively arm64')
    loads=capture(['xcrun','vtool','-show-build',path])
    expected='IOSSIMULATOR' if rid=='iossimulator-arm64' else 'IOS' if rid=='ios-arm64' else 'MACOS'
    platforms=re.findall(r'^\s*platform\s+(\S+)',loads,re.MULTILINE)
    if not platforms or any(p!=expected for p in platforms):raise ValueError('Native product platform mismatch')
    minimums=re.findall(r'^\s*minos\s+([0-9.]+)',loads,re.MULTILINE)
    if rid.startswith('ios') and (not minimums or any(tuple(map(int,m.split('.')))>(16,0,0) for m in minimums)):
        raise ValueError('Native product requires a newer iOS deployment target')
    return {'architectures':arch.split(),'buildCommands':loads}


def validate_apple_archive(path,rid):
    names=capture(['ar','t',path]).splitlines()
    if not names or len(names)>4096 or len(set(names))!=len(names):raise ValueError('Invalid native archive member inventory')
    result={}
    with tempfile.TemporaryDirectory(prefix='canopy-archive-') as temp:
        for index,name in enumerate(names):
            if len(name)>255 or '/' in name or any(ord(c)<32 for c in name):raise ValueError('Unsafe native archive member')
            if name in ('__.SYMDEF','__.SYMDEF SORTED','__.SYMDEF_64','__.SYMDEF_64 SORTED'):continue
            member=Path(temp)/(str(index)+'.o')
            with member.open('wb') as stream:run(['ar','p',path,name],stdout=stream)
            result[name]=validate_apple_product(member,rid)
    if not result:raise ValueError('Native archive has no object members')
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--inspect',action='store_true');p.add_argument('--cross-source',type=Path)
    p.add_argument('--output',type=Path);p.add_argument('--rid',choices=('osx-arm64','ios-arm64','iossimulator-arm64','linux-x64'),default='osx-arm64')
    p.add_argument('--kind',choices=('Static','Shared'),default='Static')
    p.add_argument('--cross-only',action='store_true');args=p.parse_args()
    report=metadata()
    if args.inspect:print(json.dumps(report,sort_keys=True));return
    if args.rid.startswith('ios') and args.kind=='Shared':p.error('iOS bridge must be a statically linked library')
    if not args.cross_source or not args.output:p.error('--cross-source and --output required')
    source=args.cross_source.resolve();out=args.output.resolve()
    validate_cross_source(source)
    if out.exists() and any(out.iterdir()):raise SystemExit('Output must be an empty dedicated directory')
    out.mkdir(parents=True,exist_ok=True)
    notices=out/'licenses';notices.mkdir()
    shutil.copy2(source/'LICENSE',notices/'SPIRV-Cross-LICENSE')
    shutil.copytree(source/'LICENSES',notices/'SPIRV-Cross-LICENSES')
    shutil.copy2(HERE/'LICENSE',notices/'translator-MIT.txt')
    shutil.copy2(ROOT/'vendor/ryujinx/LICENSE.txt',notices/'Ryujinx-MIT.txt')
    recipe=hashlib.sha256()
    for path in sorted([*HERE.glob('*.cs'),*HERE.glob('*.csproj'),*HERE.glob('inprocess_cross.*'),*HERE.glob('canopy_cross_budget.*'),*HERE.glob('patches/*'),*HERE.glob('cross_patches/*'),HERE/'checked_patches.py',HERE/'publish_library.py']):
        recipe.update(str(path.relative_to(HERE)).encode()+b'\0'+path.read_bytes()+b'\0')
    report['bridgeRecipeSHA256']=recipe.hexdigest()
    objects=out/'objects';objects.mkdir();flags=['-std=c++11','-O2','-fPIC']
    compiler='c++'
    if args.rid.startswith(('ios','osx')):
        sdk,target_flags=apple_flags(args.rid)
        compiler=capture(['xcrun','--sdk',sdk,'--find','clang++'])
        flags+=target_flags
        report['appleSDK']={'name':sdk,'version':capture(['xcrun','--sdk',sdk,'--show-sdk-version']),
                            'deploymentTarget':IOS_MIN if args.rid.startswith('ios') else None}
    private_cross=out/'cross-source'
    shutil.copytree(source,private_cross,ignore=shutil.ignore_patterns('.git'))
    checked_patches(private_cross,HERE/'cross_patches')
    report['patchedCrossSourceTreeSHA256']=tree_digest(private_cross)
    sources=[private_cross/name for name in CROSS_SOURCES]+[HERE/'inprocess_cross.cpp',HERE/'canopy_cross_budget.cpp']
    def compile_one(path):
        obj=objects/(path.name+'.o')
        run([compiler,*flags,'-I',private_cross,'-I',HERE,'-c',path,'-o',obj]);return obj
    with ThreadPoolExecutor(max_workers=2) as pool:compiled=list(pool.map(compile_one,sources))
    archive=out/'libcanopy_spirv_cross.a';run(['ar','rcs',archive,*compiled])
    if args.kind=='Shared' or (args.cross_only and not args.rid.startswith('ios')):
        suffix='.dylib' if args.rid.startswith('osx') else '.so'
        run([compiler,*flags,'-dynamiclib' if suffix=='.dylib' else '-shared',*compiled,'-o',out/('libcanopy_spirv_cross'+suffix)])
    validate_cross_source(source)
    report.update(rid=args.rid,kind=args.kind,crossCommit=PIN,crossCompiled=True,nativeAotCompiled=False,
                  staticConsumerLinked=False,staticConsumerExecuted=False,
                  archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                  crossArtifacts={path.name:{'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':path.stat().st_size}
                                  for path in sorted(out.glob('libcanopy_spirv_cross.*'))},managedArtifacts={})
    (out/'native-build.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    if not args.cross_only:
        if not report['dotnetAvailable']:raise SystemExit('Cross compiled; NativeAOT gate unavailable: dotnet is not installed')
        work=out/'work';ryu=work/'ryujinx';xlate=work/'xlate'
        shutil.copytree(ROOT/'vendor/ryujinx',ryu,ignore=shutil.ignore_patterns('bin','obj','.git'))
        xlate.mkdir()
        checked_patches(ryu,HERE/'patches')
        for path in HERE.iterdir():
            if path.suffix=='.cs' or path.name=='NativeLibrary.csproj':shutil.copy2(path,xlate/path.name)
        report['patchedVendorTreeSHA256']=tree_digest(ryu)
        report['managedSourceTreeSHA256']=tree_digest(xlate)
        report['managedRecipeSHA256']=hashlib.sha256(json.dumps({key:report[key] for key in
            ('bridgeRecipeSHA256','patchedVendorTreeSHA256','managedSourceTreeSHA256','rid','kind')},
            sort_keys=True,separators=(',',':')).encode()).hexdigest()
        (out/'native-build.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
        # Offline source prevents acquiring NuGet packages; existing global cache
        # may satisfy restore and creates fresh isolated project.assets.json.
        offline=work/'empty-nuget-source';offline.mkdir()
        env=dict(os.environ,DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_CLI_TELEMETRY_OPTOUT='1',
                 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true')
        link_plan=out/'native-link.args'
        properties=['-p:RyuSrc='+str(ryu),'-p:NativeLib='+args.kind,'-p:CanopyLinkPlan='+str(link_plan),'-p:GeneratePackageOnBuild=false']
        if args.rid.startswith('ios'):properties+=['-p:PublishAotUsingRuntimePack=true','-p:AppleMinOSVersion='+IOS_MIN]
        project=xlate/'NativeLibrary.csproj'
        run(['dotnet','restore',project,'-r',args.rid,'--source',offline,*properties],env=env)
        run(['dotnet','publish',project,'--no-restore','-c','Release','-r',args.rid,*properties,'-o',out/'native'],env=env)
        products=file_records(out/'native')
        suffix='.a' if args.kind=='Static' else '.dylib' if args.rid.startswith('osx') else '.so'
        if not any(name.endswith(suffix) for name in products):raise RuntimeError('NativeAOT did not emit the requested native library')
        report['managedArtifacts']=products
        report['nativeAotCompiled']=True
        if args.kind=='Static':
            managed=out/'native/CanopyShaderNative.a'
            if not managed.is_file():raise RuntimeError('Expected actual CanopyShaderNative static archive missing')
            link_arguments=read_link_plan(link_plan)
            report['nativeLinkPlanSHA256']=hashlib.sha256(link_plan.read_bytes()).hexdigest()
            report['nativeToolchainProperties']=(link_plan.with_name(link_plan.name+'.properties')).read_text(encoding='utf-8-sig').splitlines()
            probe=out/'canopy-shader-native-probe'
            probe_object=objects/'static-consumer.o'
            run([compiler,*flags,'-x','c','-std=c11','-I',HERE,'-c',ROOT/'tests/canopy_shader_native_probe.c','-o',probe_object])
            run([compiler,*flags,probe_object,managed,archive,
                 *link_arguments,'-pthread','-o',probe])
            report['staticConsumerLinked']=True
            if args.rid.startswith(('ios','osx')):
                report['staticConsumerTarget']=validate_apple_product(probe,args.rid)
                # Also inspect archive members: a compatible final executable
                # must not conceal a higher-minimum object via linker warnings.
                report['managedArchiveTarget']=validate_apple_archive(managed,args.rid)
                report['crossArchiveTarget']=validate_apple_archive(archive,args.rid)
            # iOS linking is source/toolchain proof only. No simulator setup or
            # device execution is attempted. Desktop proof runs original input.
            if (args.rid=='linux-x64' and sys.platform=='linux') or (args.rid=='osx-arm64' and sys.platform=='darwin'):
                import struct
                code=out/'original-maxwell.bin';request=out/'original-request.json'
                code.write_bytes(struct.pack('<4Q',0,0xe30000000007000f,0x50b0000000070f00,0x50b0000000070f00))
                key=hashlib.sha256(code.read_bytes()).hexdigest()
                request.write_text(json.dumps({'variant':key+'-000000000000','stage':'cs','chain':'original-static-proof-v1',
                    'local':[1,1,1],'tex':{},'img':{},'attr':{},'fout':{},'c1':'','debug':False,'depth_minus_w':False}))
                run([probe,'--self-test',code,request])
                report['staticConsumerExecuted']=True
            report['staticConsumerSHA256']=hashlib.sha256(probe.read_bytes()).hexdigest()
    report['archiveSHA256']=hashlib.sha256(archive.read_bytes()).hexdigest()
    (out/'native-build.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    print(json.dumps(report,sort_keys=True))

if __name__=='__main__':main()
