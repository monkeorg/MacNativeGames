#!/usr/bin/env python3
"""Build real in-process Cross + patched NativeAOT library, with offline restore.

No SDK/package installation or source download. Supply the exact pinned public
SPIRV-Cross checkout. Missing already-cached .NET packages are a failed gate.
An ios-arm64 attempt is not evidence of supported NativeAOT until it succeeds.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
PIN='aa217aeb6c9f0ace7a0ab233b28807edf45eb165'
CROSS_SOURCES=('spirv_cross.cpp','spirv_parser.cpp','spirv_cross_parsed_ir.cpp',
               'spirv_cfg.cpp','spirv_glsl.cpp','spirv_msl.cpp')


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
    if result['dotnetAvailable']:result['dotnetVersion']=capture(['dotnet','--version'])
    if result['xcrunAvailable']:
        result['iphoneosSDK']=capture(['xcrun','--sdk','iphoneos','--show-sdk-version'])
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--inspect',action='store_true');p.add_argument('--cross-source',type=Path)
    p.add_argument('--output',type=Path);p.add_argument('--rid',choices=('osx-arm64','ios-arm64','linux-x64'),default='osx-arm64')
    p.add_argument('--kind',choices=('Static','Shared'),default='Static')
    p.add_argument('--cross-only',action='store_true');args=p.parse_args()
    report=metadata()
    if args.inspect:print(json.dumps(report,sort_keys=True));return
    if args.rid=='ios-arm64' and args.kind=='Shared':p.error('iOS bridge must be a statically linked library')
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
    for path in sorted([*HERE.glob('*.cs'),*HERE.glob('*.csproj'),*HERE.glob('inprocess_cross.*'),*HERE.glob('patches/*.patch'),HERE/'publish_library.py']):
        recipe.update(str(path.relative_to(HERE)).encode()+b'\0'+path.read_bytes()+b'\0')
    report['bridgeRecipeSHA256']=recipe.hexdigest()
    objects=out/'objects';objects.mkdir();flags=['-std=c++11','-O2','-fPIC']
    compiler='c++'
    if args.rid in ('ios-arm64','osx-arm64'):
        sdk='iphoneos' if args.rid=='ios-arm64' else 'macosx'
        compiler=capture(['xcrun','--sdk',sdk,'--find','clang++'])
        flags+=['-isysroot',capture(['xcrun','--sdk',sdk,'--show-sdk-path']),'-arch','arm64']
        if args.rid=='ios-arm64':flags+=['-miphoneos-version-min=17.0']
    sources=[source/name for name in CROSS_SOURCES]+[HERE/'inprocess_cross.cpp']
    def compile_one(path):
        obj=objects/(path.name+'.o')
        run([compiler,*flags,'-I',source,'-c',path,'-o',obj]);return obj
    with ThreadPoolExecutor(max_workers=2) as pool:compiled=list(pool.map(compile_one,sources))
    archive=out/'libcanopy_spirv_cross.a';run(['ar','rcs',archive,*compiled])
    if args.kind=='Shared' or (args.cross_only and args.rid!='ios-arm64'):
        suffix='.dylib' if args.rid.startswith('osx') else '.so'
        run([compiler,*flags,'-dynamiclib' if suffix=='.dylib' else '-shared',*compiled,'-o',out/('libcanopy_spirv_cross'+suffix)])
    validate_cross_source(source)
    report.update(rid=args.rid,kind=args.kind,crossCommit=PIN,crossCompiled=True,nativeAotCompiled=False,
                  archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                  crossArtifacts={path.name:{'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':path.stat().st_size}
                                  for path in sorted(out.glob('libcanopy_spirv_cross.*'))},managedArtifacts={})
    (out/'native-build.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    if not args.cross_only:
        if not report['dotnetAvailable']:raise SystemExit('Cross compiled; NativeAOT gate unavailable: dotnet is not installed')
        work=out/'work';ryu=work/'ryujinx';xlate=work/'xlate'
        shutil.copytree(ROOT/'vendor/ryujinx',ryu,ignore=shutil.ignore_patterns('bin','obj','.git'))
        xlate.mkdir()
        for path in sorted((HERE/'patches').glob('*.patch')):run(['patch','-s','-p1','--forward','-i',path],cwd=ryu)
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
        properties=['-p:RyuSrc='+str(ryu),'-p:NativeLib='+args.kind]
        project=xlate/'NativeLibrary.csproj'
        run(['dotnet','restore',project,'-r',args.rid,'--source',offline,*properties],env=env)
        run(['dotnet','publish',project,'--no-restore','-c','Release','-r',args.rid,*properties,'-o',out/'native'],env=env)
        products=file_records(out/'native')
        suffix='.a' if args.kind=='Static' else '.dylib' if args.rid.startswith('osx') else '.so'
        if not any(name.endswith(suffix) for name in products):raise RuntimeError('NativeAOT did not emit the requested native library')
        report['managedArtifacts']=products
        report['nativeAotCompiled']=True
    report['archiveSHA256']=hashlib.sha256(archive.read_bytes()).hexdigest()
    (out/'native-build.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    print(json.dumps(report,sort_keys=True))

if __name__=='__main__':main()
