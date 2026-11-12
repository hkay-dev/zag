# dmgbuild settings for Zag.dmg: Zag.app beside an Applications shortcut on a
# warm Paper card background. Invoked via scripts/dmg.sh from the repo root.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects defines)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

background = "dmg/background.png"
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 12
icon_locations = {
    os.path.basename(app): (180, 168),
    "Applications": (480, 168),
}
