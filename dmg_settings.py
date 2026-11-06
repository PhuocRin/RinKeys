# Cấu hình cửa sổ cài đặt .dmg cho dmgbuild (https://dmgbuild.readthedocs.io).
# build.sh truyền đường dẫn app vào qua -D app=...
import os.path

app = defines.get("app", "build/RinKeys.app")  # noqa: F821 (dmgbuild tự cung cấp 'defines')
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]

# Ổ đĩa khi mở .dmg cũng mang icon RinKeys.
_icns = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
if os.path.exists(_icns):
    icon = _icns
symlinks = {"Applications": "/Applications"}

# Nền kính mờ; dmgbuild tự ghép bản @2x cho màn hình Retina.
background = "assets/dmg-background.png"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Cao hơn nền 400 để Finder có bật thanh đường dẫn / thanh trạng thái vẫn không che dòng nhắc phía dưới.
window_rect = ((200, 100), (600, 500))
default_view = "icon-view"

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    appname: (150, 178),
    "Applications": (450, 178),
}
