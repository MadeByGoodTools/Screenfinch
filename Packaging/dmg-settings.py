from pathlib import Path

app = Path(defines["app"])
package = Path(defines["installer"])
files = [str(app), str(package)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/Screenfinch.icns")
background = defines["background"]
format = "UDZO"
compression_level = 9
window_rect = ((160, 100), (660, 520))
icon_size = 68
text_size = 13
hide_extensions = [package.name]
icon_locations = {
    app.name: (167, 200),
    "Applications": (493, 200),
    package.name: (493, 354),
}
