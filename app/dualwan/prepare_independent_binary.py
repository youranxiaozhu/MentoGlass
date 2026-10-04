"""Prepare a second local instance of the exact router binary, without altering authentication.

Usage: python3 prepare_independent_binary.py ORIGINAL_BINARY OUTPUT_BINARY
This tool does not connect to the router or accept any account credentials.
Only four equal-length static paths are changed. The original file is left intact.
"""
from pathlib import Path
import hashlib
import sys

EXPECTED_ORIGINAL = 'd711a8093e259fb725a85df65531d73388b2f340e9eb7235ee1c0e2ebf01105b'
EXPECTED_SECOND = '0b909e53d7bbcdd17eed281f93a6ab6a218f1ad6b54eabbf3313bf5ab7389088'


def prepare(data):
    if hashlib.sha256(data).hexdigest() != EXPECTED_ORIGINAL:
        raise ValueError('Unrecognized binary; no changes made. Review this firmware before adapting it.')
    modified = data
    for old in [b'/etc/mentohust.conf\0', b'/tmp/mentohust.pid\0', b'/tmp/mentohust.log\0', b'/etc/mentohust/\0']:
        if modified.count(old) != 1:
            raise ValueError('Unexpected path occurrence count; stopped.')
        modified = modified.replace(old, old.replace(b'mentohust', b'mentohus2'))
    if len(modified) != len(data) or sum(a != b for a, b in zip(data, modified)) != 4:
        raise ValueError('Unexpected binary changes; stopped.')
    if hashlib.sha256(modified).hexdigest() != EXPECTED_SECOND:
        raise ValueError('Second-instance checksum mismatch; stopped.')
    return modified


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    original, destination = map(Path, sys.argv[1:])
    if original.resolve() == destination.resolve() or destination.exists():
        raise SystemExit('Choose a new destination; the original binary must remain intact.')
    output = prepare(original.read_bytes())
    destination.write_bytes(output)
    destination.chmod(0o700)
    print('Prepared independent config, lock and log paths; four bytes changed; checksum verified.')
