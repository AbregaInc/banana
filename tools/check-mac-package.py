#!/usr/bin/env python3
"""Verify the exported Mac App Store payload, including resource bundle signers."""
import argparse
import hashlib
import plistlib
from pathlib import Path
import subprocess
import tempfile


MACHO = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca',
    'cafebabf', 'bfbafeca')}


def command(args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        # Tool diagnostics can include private certificate names or profile IDs.
        raise ValueError(f'{args[0]} failed for {Path(args[-1]).name}')
    return result.stdout


def is_macho(path):
    with path.open('rb') as file:
        return file.read(4) in MACHO


def leaf_certificate(path, directory):
    prefix = str(directory / 'certificate')
    for file in directory.glob('certificate*'):
        file.unlink()
    result = subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(path)],
                            capture_output=True)
    certificate = Path(prefix + '0')
    return certificate.read_bytes() if result.returncode == 0 and certificate.exists() else None


def resource_only(bundle):
    info = bundle / 'Contents/Info.plist'
    if not info.exists():
        info = bundle / 'Info.plist'
    if not info.exists() or plistlib.loads(info.read_bytes()).get('CFBundleExecutable'):
        return False
    return not any(is_macho(file) for file in bundle.rglob('*') if file.is_file())


def unsigned_bundle(bundle):
    result = subprocess.run(['codesign', '-d', str(bundle)], capture_output=True)
    return result.returncode != 0 and b'not signed at all' in result.stderr


def check_signer(label, certificate, allowed, unsigned_resource=False):
    if certificate is None and unsigned_resource:
        return
    if certificate is None or hashlib.sha256(certificate).digest() not in allowed:
        raise ValueError(f'{label}: signer is not authorized by the app provisioning profile')


def check_app(app, scratch):
    command(['codesign', '--verify', '--deep', '--strict', str(app)])
    profile = plistlib.loads(command(['security', 'cms', '-D', '-i',
                                      str(app / 'Contents/embedded.provisionprofile')]))
    allowed = {hashlib.sha256(cert).digest() for cert in profile['DeveloperCertificates']}
    if not allowed:
        raise ValueError('The provisioning profile authorizes no signing certificates')
    bundles = [app, *(path for path in app.rglob('*') if path.is_dir()
                     and path.suffix in ('.app', '.appex', '.framework', '.xpc', '.bundle'))]
    unsigned = 0
    for bundle in bundles:
        leaf = leaf_certificate(bundle, scratch)
        resource = (bundle.suffix == '.bundle'
                    and bundle.parent == app / 'Contents/Resources'
                    and resource_only(bundle) and unsigned_bundle(bundle))
        check_signer(bundle.relative_to(app.parent), leaf, allowed, resource)
        unsigned += int(leaf is None and resource)
    images = [file for file in app.rglob('*') if file.is_file() and is_macho(file)]
    for file in images:
        check_signer(file.relative_to(app.parent), leaf_certificate(file, scratch), allowed)
    return {'bundles': len(bundles), 'images': len(images), 'sealedResourceBundles': unsigned}


def check_package(package):
    command(['pkgutil', '--check-signature', str(package)])
    with tempfile.TemporaryDirectory(prefix='banana-package-check-') as directory:
        scratch = Path(directory)
        expanded = scratch / 'expanded'
        command(['pkgutil', '--expand-full', str(package), str(expanded)])
        apps = list(expanded.glob('*/Payload/*.app'))
        if len(apps) != 1:
            raise ValueError('The package must contain one primary Mac app')
        return check_app(apps[0], scratch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    try:
        counts = check_package(args.package.resolve())
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'Mac package rejected: {error}\n')
    print(f'Mac package signing passed: {counts}')


if __name__ == '__main__':
    main()
