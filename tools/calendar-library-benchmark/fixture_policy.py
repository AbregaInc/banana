"""Reject benchmark binaries that ignore the requested fixture configuration."""


def matches_fixture(data, profile, seed, hidden_calendars=''):
    expected = dict(profile=profile, seed=str(seed),
                    calendarCount=12 if profile == 'varied-v1' else 1,
                    hiddenCalendars=sorted({int(v) for v in hidden_calendars.split(',') if v}))
    fixture = data.get('fixture')
    return isinstance(fixture, dict) and all(fixture.get(k) == v for k, v in expected.items())
