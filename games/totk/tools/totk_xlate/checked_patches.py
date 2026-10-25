"""Apply reviewed exact-byte patches only to private dependency copies."""
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    if path.is_symlink() or not path.is_file():raise ValueError('Patch target must be a regular original file')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_checked(root,folder):
    root=Path(root).resolve();folder=Path(folder)
    document=json.loads((folder/'input-sha256.json').read_bytes())
    if document.get('schemaVersion')!=1:raise ValueError('Unknown checked patch manifest')
    for record in document['patches']:
        patch=folder/record['patch']
        if digest(patch)!=record['sha256']:raise ValueError('Patch bytes differ from reviewed recipe')
        for name,expected in record['before'].items():
            target=root/name
            if not target.resolve().is_relative_to(root):raise ValueError('Patch target escapes private source')
            if expected is None:
                if target.exists() or target.is_symlink():raise ValueError('New patch target already exists')
            elif digest(target)!=expected:raise ValueError('Original dependency bytes differ from checked patch precondition: '+name)
        subprocess.run(['patch','--batch','--fuzz=0','-s','-p1','--forward','-i',str(patch.resolve())],cwd=root,check=True)
        for name,expected in record['after'].items():
            if digest(root/name)!=expected:raise ValueError('Patched dependency bytes differ from reviewed result: '+name)


if __name__=='__main__':
    import sys
    if len(sys.argv)!=3:raise SystemExit('usage: checked_patches.py PRIVATE_COPY PATCH_FOLDER')
    apply_checked(sys.argv[1],sys.argv[2])
