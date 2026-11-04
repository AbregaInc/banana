"""Separate artifact identities and update routes; old manifests default to Stable."""
CHANNELS = {
    'stable': {'tag': 'mac-v', 'updates': 'updates/mac', 'download': '/download/mac'},
    'beta': {'tag': 'mac-beta-v', 'updates': 'updates/mac-beta', 'download': '/download/mac-beta'},
}


def channel_config(channel):
    if channel not in CHANNELS:
        raise ValueError('Distribution channel must be stable or beta')
    return CHANNELS[channel]


def validate_identity(info, channel):
    config = channel_config(channel)
    if info.get('BananaReleaseChannel', 'stable') != channel:
        raise ValueError('App and release channels differ')
    if info['CFBundleIdentifier'].endswith('.beta') != (channel == 'beta'):
        raise ValueError('App bundle identity does not match channel')
    expected = 'https://bananatheapp.com/' + config['updates'] + '/appcast.xml'
    if info.get('SUFeedURL') != expected:
        raise ValueError('Update feed does not match channel')
    return config
