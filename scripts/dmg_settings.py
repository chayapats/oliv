# dmgbuild settings for the OLIV installer dmg (used by scripts/release.sh).
#
# dmgbuild (https://dmgbuild.readthedocs.io/) writes the Finder view options
# (.DS_Store) programmatically — no AppleScript, no Finder automation, no TCC
# prompts — so the "drag to Applications" window comes out styled and identical
# on every run: fixed 660x400 window, custom background with the arrow, the app
# and the /Applications symlink pinned to the two icon slots, volume icon set.
#
# Invoked as:
#   dmgbuild -s scripts/dmg_settings.py \
#       -D app=<path to OLIV.app> -D background=<bg.tiff> -D icon=<AppIcon.icns> \
#       "OLIV X.Y.Z" dist/OLIV-X.Y.Z.dmg
#
# Geometry contract: icon_locations + window size here must match what
# scripts/make_dmg_background.py draws (arrow position, caption) — change them
# together.

app = defines["app"]  # noqa: F821  (dmgbuild injects `defines`)

# UDZO (zlib) like the previous hand-rolled hdiutil dmg — safe everywhere.
format = "UDZO"

# Volume icon: the app's own compiled icon, so the mounted disk on the Desktop
# and in the Finder sidebar shows the OLIV mark instead of a generic drive.
icon = defines["icon"]  # noqa: F821

files = [(app, "OLIV.app")]
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # noqa: F821

# ((x, y), (w, h)) of the Finder window; content area matches the background.
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
icon_locations = {
    "OLIV.app": (165, 240),
    "Applications": (495, 240),
}
