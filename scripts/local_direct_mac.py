#!/usr/bin/env python3
"""Fixed-tag local-direct launch and live identity checks; no cloud setup."""
import argparse
import base64
import ctypes
import json
import os
import plistlib
import shlex
import socket
import stat
import struct
import subprocess
import tempfile
import time
from pathlib import Path

TAG = 'local-terminal-device'
MAC_BUNDLE = 'com.cmuxterm.app.debug.local.terminal.device'
MAC_SOCKET = '/tmp/cmux-debug-local-terminal-device.sock'  # nosec B108: fixed tagged socket; owner and kernel peer PID verified below.


def require(value, message):
    if not value:
        raise ValueError(message)


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except json.JSONDecodeError as error:
        raise ValueError('Invalid private receipt JSON') from error


def validate_mac_identity(identity, executable, app):
    for key, expected in {'bundle_identifier': MAC_BUNDLE, 'socket_path': MAC_SOCKET,
                          'app_executable_path': executable, 'app_bundle_path': app}.items():
        require(identity.get(key) == expected, 'Mac identity mismatch: ' + key)


def private_path(path):
    path = Path(path)
    require(not path.is_symlink(), 'Symlink receipt/state refused')
    metadata = path.stat()
    require(metadata.st_uid == os.getuid() and metadata.st_mode & 0o077 == 0, 'State must be private and owned')
    return path


def socket_password_directory(root):
    current = private_path(root)
    require(stat.S_ISDIR(current.lstat().st_mode), 'State root is not a directory')
    for part in ['home', '.local', 'state', 'cmux']:
        current = private_path(current / part)
        require(stat.S_ISDIR(current.lstat().st_mode) and stat.S_IMODE(current.stat().st_mode) == 0o700,
                'Socket state directory must be owned 0700')
    return current


def create_isolated_socket_password(root):
    directory = socket_password_directory(root)
    descriptor = os.open(directory / 'socket-control-password', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(base64.b64encode(os.urandom(32)))
        output.flush()
        os.fsync(output.fileno())
    require_isolated_socket_password(root)


def require_isolated_socket_password(root):
    # A nonempty private file prevents the existing CLI's shared Keychain fallback.
    path = socket_password_directory(root) / 'socket-control-password'
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        metadata = os.fstat(source.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
                and stat.S_IMODE(metadata.st_mode) == 0o600 and metadata.st_nlink == 1,
                'Socket password must be owned regular 0600')
        value = source.read(45)
        require(len(value) == 44, 'Invalid isolated socket password length')
        require(len(base64.b64decode(value, validate=True)) == 32, 'Invalid isolated socket password encoding')


def process_path(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    buffer = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(int(pid), buffer, len(buffer)) > 0, 'Mac PID is not live')
    return buffer.value.decode()


def process_start(pid):
    return subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='], env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}).decode().strip()


def validate_bundle(app):
    app = Path(app).resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == MAC_BUNDLE, 'Wrong Mac bundle')
    environment = info.get('LSEnvironment', {})
    require(environment.get('CMUX_TAG') == TAG, 'Wrong Mac tag')
    for nested in [*app.rglob('*.appex'), *app.rglob('*.systemextension')]:
        meta = plistlib.loads((nested / 'Contents/Info.plist').read_bytes())
        nested_id = meta.get('CFBundleIdentifier', '')
        # Existing tagged reload also applies the exact tag ID to its dormant tunnel target.
        require(nested_id == MAC_BUNDLE or nested_id.startswith(MAC_BUNDLE + '.'), 'Unisolated nested identity')
    name = info.get('CFBundleExecutable', '')
    require(bool(name) and Path(name).name == name and name not in ['.', '..'], 'Invalid Mac executable name')
    executable = app / 'Contents/MacOS' / name
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return app, executable


def terminal_identify(root):
    # One read-only startup command in the newly created task terminal respects
    # cmuxOnly ancestry. No exported capability, new socket API or background service.
    root = private_path(root).resolve(strict=True)
    record = read_json(private_path(root / 'launch-receipt.json'))
    app, executable = validate_bundle(record['app_path'])
    require(process_path(record['pid']) == str(executable), 'Task Mac process mismatch')
    require_isolated_socket_password(root)
    clean = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(root / 'home'),
             'CFFIXED_USER_HOME': str(root / 'home'), 'CMUX_TAG': TAG,
             'CMUX_DERIVED_DATA': str(app.parents[3])}
    output = subprocess.check_output([str(Path(__file__).resolve().parent / 'cmux-debug-cli.sh'),
                                      '--json', 'identify'], env=clean, cwd=root, timeout=10)
    (root / 'identity.json').write_bytes(output)


def verify_mac(receipt):
    record = read_json(private_path(receipt))
    root = private_path(record['state_directory']).resolve(strict=True)
    require(Path(receipt).resolve().parent == root, 'Receipt outside owned state')
    require(record.get('tag') == TAG, 'Wrong receipt tag')
    app, executable = validate_bundle(record['app_path'])
    pid = record['pid']
    require(process_path(pid) == str(executable), 'Mac executable does not match PID')
    start = process_start(pid)
    require(start == record['process_start'], 'Mac PID was reused')
    env = subprocess.check_output(['ps', 'eww', '-p', str(pid), '-o', 'command=']).decode()
    for key, value in {'HOME': root / 'home', 'CFFIXED_USER_HOME': root / 'home',
                       'XDG_CONFIG_HOME': root / 'home/.config', 'XDG_STATE_HOME': root / 'home/.local/state',
                       'CMUX_SOCKET_PATH': MAC_SOCKET}.items():
        require((' ' + key + '=' + str(value) + ' ') in (' ' + env.strip() + ' '), 'Mac isolation environment mismatch: ' + key)
    for forbidden in ['CMUX_UITEST_STACK_', 'CMUX_DOGFOOD_STACK_', 'CMUX_DEV_AUTH_', 'CMUX_ATTACH_']:
        require(forbidden not in env, 'Cloud environment found')
    private_path(MAC_SOCKET)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(MAC_SOCKET)
        # Darwin LOCAL_PEERPID: kernel identity, not a receipt's claim.
        peer = struct.unpack('i', client.getsockopt(0, 2, 4))[0]
        require(peer == pid, 'Mac socket belongs to another PID')
    require_isolated_socket_password(root)
    # The startup response came from the official CLI inside this task's terminal.
    # It is not standalone proof: above we independently recheck live kernel peer
    # PID, executable signature/path, start time and isolation environment.
    identity = read_json(private_path(root / 'identity.json'))
    validate_mac_identity(identity, str(executable), str(app))
    open_files = subprocess.check_output(['lsof', '-a', '-p', str(pid), '-Fn'], timeout=10).decode()
    (root / 'open-files.log').write_text(open_files)
    require(str(root / 'home/.config/cmux') in open_files, 'Cannot prove live isolated config watcher')
    return record


def launch(app_path):
    require(not Path(MAC_SOCKET).exists(), 'Tag socket already exists; refusing replacement')
    app, executable = validate_bundle(app_path)
    running = subprocess.check_output(['ps', 'ax', '-o', 'comm=']).decode().splitlines()
    require(str(executable) not in [line.strip() for line in running], 'Tag is already running')
    root = Path(tempfile.mkdtemp(prefix='cmux-direct-mac.', dir='/tmp')).resolve()
    home = root / 'home'
    for path in [home / '.config/cmux', home / '.config/ghostty', home / '.local/state/cmux', root / 'tmp', root / 'work']:
        path.mkdir(parents=True, mode=0o700)
    (home / '.config/cmux/cmux.json').write_text('{}\n')
    bootstrap = root / 'terminal-start.sh'
    bootstrap.write_text('#!/bin/bash\n/usr/bin/python3 -I ' + shlex.quote(str(Path(__file__).resolve()))
                         + ' --tag ' + TAG + ' --terminal-identity-root ' + shlex.quote(str(root))
                         + '\nexec /bin/bash --noprofile --norc\n')
    (home / '.config/ghostty/config').write_text('command = /bin/bash --noprofile --norc '
        + str(bootstrap) + '\nworking-directory = ' + str(root / 'work') + '\n')
    create_isolated_socket_password(root)
    secret = base64.b64encode(os.urandom(32)).decode()
    (root / 'resume-secret').write_text(secret)
    user = subprocess.check_output(['id', '-un']).decode().strip()
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'USER': user, 'LOGNAME': user,
                   'HOME': str(home), 'CFFIXED_USER_HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
                   'XDG_STATE_HOME': str(home / '.local/state'), 'TMPDIR': str(root / 'tmp'), 'LANG': 'en_US.UTF-8',
                   'CMUX_SOCKET_PATH': MAC_SOCKET, 'CMUX_TAG': TAG,
                   'CMUX_SURFACE_RESUME_APPROVAL_SECRET_B64': secret}
    require_isolated_socket_password(root)
    with (root / 'launch.log').open('wb') as log:
        process = subprocess.Popen([str(executable)], cwd=root / 'work', env=environment, stdout=log, stderr=log,
                                   start_new_session=True)
    receipt = root / 'launch-receipt.json'
    record = {'tag': TAG, 'pid': process.pid, 'state_directory': str(root), 'app_path': str(app),
              'process_start': process_start(process.pid)}
    receipt.write_text(json.dumps(record, indent=2))
    print('Private launch receipt: ' + str(receipt), flush=True)
    try:
        for _ in range(30):
            require(process.poll() is None, 'Mac exited during startup')
            if Path(MAC_SOCKET).exists() and (root / 'identity.json').exists():
                break
            time.sleep(1)
        verify_mac(receipt)
        print('MAC_ISOLATED_RUNNING')
    except Exception:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)
        raise


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True, choices=[TAG])
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--app')
    action.add_argument('--terminal-identity-root', type=Path)
    args = parser.parse_args()
    if args.app:
        launch(args.app)
    else:
        terminal_identify(args.terminal_identity_root)
