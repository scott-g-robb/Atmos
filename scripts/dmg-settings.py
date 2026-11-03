import os

app = defines['app']
background = defines['background']
files = [app]
symlinks = {'Applications': '/Applications'}
format = 'UDZO'
filesystem = 'HFS+'
icon_locations = {os.path.basename(app): (155, 198), 'Applications': (445, 198)}
window_rect = ((200, 160), (600, 380))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 104
text_size = 13
arrange_by = None
