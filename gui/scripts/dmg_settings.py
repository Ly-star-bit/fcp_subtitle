"""dmgbuild settings: drag-to-Applications layout with instruction background.

Used by package_app.sh:
  uv run --with dmgbuild dmgbuild -s dmg_settings.py -D app=<path/to/.app> "卷名" out.dmg
"""

import os.path

app = defines.get("app")  # noqa: F821  (defines is injected by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines.get("background")  # noqa: F821

window_rect = ((200, 160), (600, 420))
default_view = "icon-view"
icon_size = 100
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_locations = {
    app_name: (150, 210),
    "Applications": (450, 210),
}
