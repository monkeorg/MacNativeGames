"""Sign a standalone UI runner with an existing identity; prepare an installed-artifact test run.

This script performs local work only. It never installs or starts anything on a device.
"""
import argparse
import hashlib
import plistlib
import secrets
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        # Commands can contain keychain passwords. Keep their arguments out of exceptions.
        raise RuntimeError(f'{Path(args[0]).name} failed with exit {result.returncode}; private arguments omitted')
    return result.stdout


def prepare(args):
    products = args.products.resolve()
    source_run = next(products.glob('*.xctestrun'))
    configuration = plistlib.loads(source_run.read_bytes())
    target = configuration['DeviceLauncherUI']
    runner = products / 'Debug-iphoneos/DeviceLauncherUI-Runner.app'
    bundle = plistlib.loads((runner / 'Info.plist').read_bytes())['CFBundleIdentifier']
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(args.profile)))
    allowed = profile['Entitlements']['application-identifier']
    prefix = profile['ApplicationIdentifierPrefix'][0]
    application = prefix + '.' + bundle
    if not (allowed == application or (allowed.endswith('.*') and application.startswith(allowed[:-1]))):
        raise RuntimeError('Provisioning profile does not cover the runner bundle')
    if not profile['Entitlements'].get('get-task-allow'):
        raise RuntimeError('UI runner requires a development provisioning profile')
    certificate = profile['DeveloperCertificates'][0]
    identity = hashlib.sha1(certificate).hexdigest().upper()
    entitlements = {
        'application-identifier': application,
        'com.apple.developer.team-identifier': profile['TeamIdentifier'][0],
        'get-task-allow': True,
        'keychain-access-groups': [application],
    }
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='launcher-ui-sign-') as temporary:
        temporary = Path(temporary)
        keychain = temporary / 'signing.keychain-db'
        keychain_password = secrets.token_urlsafe(24)
        run('security', 'create-keychain', '-p', keychain_password, str(keychain))
        try:
            run('security', 'unlock-keychain', '-p', keychain_password, str(keychain))
            run('security', 'import', str(args.p12), '-k', str(keychain), '-P',
                args.password_file.read_text().strip(), '-T', '/usr/bin/codesign')
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
                '-k', keychain_password, str(keychain))
            identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
            if identity not in identities:
                raise RuntimeError('Existing identity does not match the provisioning profile')
            entitlement_file = temporary / 'runner-entitlements.plist'
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            shutil.copyfile(args.profile, runner / 'embedded.mobileprovision')
            for test in (runner / 'PlugIns').glob('*.xctest'):
                run('codesign', '--force', '--sign', identity, '--keychain', str(keychain), str(test))
            run('codesign', '--force', '--sign', identity, '--keychain', str(keychain),
                '--entitlements', str(entitlement_file), str(runner))
            run('codesign', '--verify', '--deep', '--strict', str(runner))
        finally:
            run('security', 'delete-keychain', str(keychain))
    target['UseDestinationArtifacts'] = True
    target['TestHostBundleIdentifier'] = bundle
    target['TestBundleDestinationRelativePath'] = '__TESTHOST__/PlugIns/DeviceLauncherUI.xctest'
    target['UITargetAppBundleIdentifier'] = 'com.smartvelo.totk'
    target['DependentProductPaths'] = []
    transfer_file = args.output / 'transfer-name.txt'
    if not transfer_file.exists():
        transfer_file.write_text('LauncherRoundtrip-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S'))
    target.setdefault('EnvironmentVariables', {})['TOTK_TEST_EXPORT_NAME'] = transfer_file.read_text().strip()
    for field in ('TestBundlePath', 'TestHostPath', 'UITargetAppPath'):
        target.pop(field, None)
    output = args.output / 'InstalledDeviceLauncher.xctestrun'
    output.write_bytes(plistlib.dumps(configuration))
    print(f'Runner signature verified: {runner}')
    print(f'Installed-artifact run prepared: {output}')
    print('No device action performed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('products', 'profile', 'p12', 'password-file', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    prepare(parser.parse_args())
