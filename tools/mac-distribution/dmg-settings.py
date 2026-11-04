"""Finder layout; dmgbuild writes metadata without driving Finder."""
from pathlib import Path
import plistlib
application = Path(defines['app']).resolve()
format = 'UDZO'
files = [str(application)]
symlinks = {'Applications': '/Applications'}
background = str(Path(defines['background']).resolve())
info = plistlib.loads((application / 'Contents/Info.plist').read_bytes())
icon_name = info.get('CFBundleIconFile', 'AppIcon')
if not icon_name.endswith('.icns'): icon_name += '.icns'
icon = str(application / 'Contents/Resources' / icon_name)
hide_extensions = [application.name]
window_rect = ((120, 120), (720, 480))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 104
text_size = 14
label_pos = 'bottom'
icon_locations = {application.name: (194, 278), 'Applications': (520, 278)}
