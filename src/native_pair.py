"""Explicit USB enrollment into the native iPhone app. No route changes."""
import hashlib
import json
import re
import socket

import pairing
import pc_test
import phone_network as protocol


def code(config):
    pairing.validate(config)
    digest = hashlib.sha256(config['token'].encode('ascii')).digest()
    return f'{int.from_bytes(digest[:4], "big") % 1_000_000:06d}'


def enroll(config):
    pairing.validate(config)
    name = re.sub(r'[^A-Za-z0-9 ._-]', '-', socket.gethostname())[:80] or 'Windows PC'
    try:
        connection = pc_test.connect_phone(config, 18764)
    except (OSError, RuntimeError) as error:
        raise RuntimeError('Open USB Internet on your iPhone, close iSH, and tap Pair with PC. Then try again.') from error
    with connection:
        connection.settimeout(125)
        protocol.reply(connection, op='pair-native', version=1, token=config['token'], name=name)
        result = json.loads(protocol.read_frame(connection, 4096))
        if not isinstance(result, dict) or result.get('ok') is not True:
            raise RuntimeError('Pairing was not approved on the phone. Tap Pair with PC and try again.')
        if (result.get('service') != 'native-ios' or type(result.get('version')) is not int
                or result['version'] != 1 or result.get('code') != code(config)):
            raise RuntimeError('The phone returned an unexpected pairing confirmation.')
    return 'Native iPhone app paired. Tap Start sharing on the phone, then Check phone here.'
