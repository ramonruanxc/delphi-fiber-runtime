"""Download the pinned official Boss CLI and verify its release checksum."""
import hashlib
import pathlib
import platform
import tarfile
import urllib.request
import zipfile

VERSION = '3.0.17'
HASHES = {
    'boss_Windows_x86_64.zip': 'aac660435608a9e6a4a05eb9ee9a2c4a0a6156d5efe6e48f48fa1227006cda5d',
    'boss_Linux_x86_64.tar.gz': 'c40ec124f4f2563b6c873dbeeba2dfad6b80b644a0f765a7291bd9efd0b21e3e',
    'boss_Darwin_x86_64.tar.gz': 'dfa8658d0276d7d48a5829577e7de86615a6d31543efd308c7795cbe0be4f4d1',
    'boss_Darwin_arm64.tar.gz': '870ff4432a8a4fcc85dfc176cb47e10685e42ad108edce77deb5d86034d2c80f',
}


def install(destination):
    destination = pathlib.Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    system = platform.system()
    cpu = {'amd64': 'x86_64', 'x86_64': 'x86_64', 'aarch64': 'arm64',
           'arm64': 'arm64'}.get(platform.machine().lower())
    extension = '.zip' if system == 'Windows' else '.tar.gz'
    asset = f'boss_{system}_{cpu}{extension}'
    if asset not in HASHES:
        raise ValueError('No pinned Boss download for this host: ' + asset)
    archive = destination / asset
    if not archive.exists():
        url = f'https://github.com/HashLoad/boss/releases/download/v{VERSION}/{asset}'
        with urllib.request.urlopen(url, timeout=90) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[asset]:
        raise ValueError('Boss release archive checksum mismatch: ' + str(archive))
    name = 'boss.exe' if system == 'Windows' else 'boss'
    # Extract only the named executable; archive paths never become local paths.
    if extension == '.zip':
        with zipfile.ZipFile(archive) as source:
            data = source.read(name)
    else:
        with tarfile.open(archive) as source:
            member = source.getmember(name)
            if not member.isfile():
                raise ValueError('Boss archive executable is not a regular file')
            data = source.extractfile(member).read()
    binary = destination / name
    binary.write_bytes(data)
    binary.chmod(0o755)
    return binary
