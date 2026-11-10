#!/usr/bin/env bash
# =============================================================================
#  build.sh — Witrn USB Tester (macOS)
#  Nạp firmware WITRN K2 / CC1 (chế độ DFU) và Monitor cho K2 (đồ thị V/A/W, REC, gói USB PD; chỉ đọc).
#  Cần: Xcode Command Line Tools (swiftc). Không cần Python hay hidapi.
#
#    ./build.sh            # build + cài app vào /Applications
#    ./build.sh run        # mở app
#    ./build.sh test [FILE]  # tự kiểm tra Monitor; có FILE (.k2 / .cc1 / .zip) thì thử cả quy trình nạp trên thiết bị giả lập
#    ./build.sh uninstall  # gỡ app
# =============================================================================
set -euo pipefail
APP_NAME="Witrn USB Tester"; EXEC_NAME="WitrnUSBTester"; BUNDLE_ID="local.witrn-usb-tester"
OLD_APPS=("K2 Update" "Witrn Update" "Witrn Monitor"); OLD_EXECS=(K2Update WitrnUpdate WitrnMonitor)   # app cũ đã gộp vào đây, gỡ khi cài
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_B='\033[1;34m'; C_0='\033[0m'
info() { echo -e "${C_B}>>${C_0} $*"; }; ok() { echo -e "${C_G}✔${C_0} $*"; }; warn() { echo -e "${C_Y}!${C_0} $*"; }; die() { echo -e "${C_R}✖ $*${C_0}" >&2; exit 1; }

make_icns() {
  cat > "$1/icon.swift" <<'ICON_EOF'
import AppKit
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S)); img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: S, height: S).insetBy(dx: S * 0.09, dy: S * 0.09)
let bg = NSBezierPath(roundedRect: rect, xRadius: S * 0.2, yRadius: S * 0.2)
NSGradient(starting: NSColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 1), ending: NSColor(red: 0.16, green: 0.36, blue: 0.62, alpha: 1))!.draw(in: bg, angle: -60)
let para = NSMutableParagraphStyle(); para.alignment = .center
let k2 = NSAttributedString(string: "W", attributes: [.font: NSFont.systemFont(ofSize: S * 0.42, weight: .black), .foregroundColor: NSColor.white, .paragraphStyle: para])
let sz = k2.size(); k2.draw(in: NSRect(x: (S - sz.width) / 2, y: S * 0.14, width: sz.width, height: sz.height))
// mũi tên lên = nâng cấp
let arrow = NSBezierPath()
let cx = S * 0.5, top = S * 0.84, w = S * 0.13
arrow.move(to: NSPoint(x: cx, y: top)); arrow.line(to: NSPoint(x: cx - w, y: top - w)); arrow.line(to: NSPoint(x: cx - w * 0.4, y: top - w))
arrow.line(to: NSPoint(x: cx - w * 0.4, y: top - w * 1.9)); arrow.line(to: NSPoint(x: cx + w * 0.4, y: top - w * 1.9))
arrow.line(to: NSPoint(x: cx + w * 0.4, y: top - w)); arrow.line(to: NSPoint(x: cx + w, y: top - w)); arrow.close()
NSColor(red: 1.0, green: 0.62, blue: 0.15, alpha: 1).setFill(); arrow.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
ICON_EOF
  swiftc -O -framework AppKit -o "$1/mkicon" "$1/icon.swift" 2>/dev/null || { warn "Không tạo được icon"; return 1; }
  "$1/mkicon" "$1/icon.png" || return 1
  local set="$1/App.iconset"; rm -rf "$set"; mkdir -p "$set"
  for s in 16 32 128 256 512; do sips -z $s $s "$1/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null; sips -z $((s*2)) $((s*2)) "$1/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null; done
  iconutil -c icns "$set" -o "$2"
}

do_app() {
  command -v swiftc >/dev/null 2>&1 || die "Thiếu Xcode Command Line Tools: xcode-select --install"
  local build; build=$(mktemp -d "${TMPDIR:-/tmp}/witrn-usb-tester.XXXXXX")
  local app="$build/$APP_NAME.app" contents="$build/$APP_NAME.app/Contents"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  info "Biên dịch $APP_NAME"
  # build cho cả Apple Silicon lẫn Intel, chạy từ macOS 11 (Big Sur)
  local arch
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos11.0" -framework Cocoa -framework SwiftUI -framework IOKit \
           -framework UniformTypeIdentifiers -o "$build/$EXEC_NAME.$arch" "$HERE/main.swift"
  done
  lipo -create "$build/$EXEC_NAME.arm64" "$build/$EXEC_NAME.x86_64" -output "$contents/MacOS/$EXEC_NAME"
  ok "đã biên dịch"
  info "Tạo icon"; make_icns "$build" "$contents/Resources/App.icns" && ok "icon OK" || true
  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>App</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>WITRN Firmware</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleTypeExtensions</key><array><string>k2</string><string>cc1</string><string>k2pic</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>WITRN Measurement Log</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>CFBundleTypeExtensions</key><array><string>csv</string><string>wpd</string></array></dict>
  </array>
</dict></plist>
PLIST
  echo "APPL????" > "$contents/PkgInfo"
  xattr -cr "$app" 2>/dev/null || true
  # ký bằng cert tự ký cố định; thiếu cert thì ký ad-hoc
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"HupVoiShot Dev"'; then
    codesign --force --deep --sign "HupVoiShot Dev" "$app" >/dev/null 2>&1 && ok "đã ký bằng HupVoiShot Dev" || warn "codesign bằng HupVoiShot Dev thất bại"
  else
    codesign --force --deep --sign - "$app" >/dev/null 2>&1 || warn "codesign thất bại (app vẫn chạy được)"
  fi
  local dir="$INSTALL_DIR"; [ -w "$dir" ] || { dir="$HOME/Applications"; mkdir -p "$dir"; }
  pkill -x "$EXEC_NAME" 2>/dev/null || true
  local i; for i in "${!OLD_APPS[@]}"; do pkill -x "${OLD_EXECS[$i]}" 2>/dev/null || true; rm -rf "$dir/${OLD_APPS[$i]}.app"; done
  rm -rf "$dir/$APP_NAME.app"; cp -R "$app" "$dir/$APP_NAME.app"; rm -rf "$build"
  ok "Đã cài: $dir/$APP_NAME.app"
}
installed() { local a="$INSTALL_DIR/$APP_NAME.app"; [ -d "$a" ] || a="$HOME/Applications/$APP_NAME.app"; echo "$a"; }
case "${1:-app}" in
  app|all) do_app ;;
  run) open "$(installed)" ;;
  test) "$(installed)/Contents/MacOS/$EXEC_NAME" --selftest-monitor; "$(installed)/Contents/MacOS/$EXEC_NAME" --selftest-custom; [ -z "${2:-}" ] || "$(installed)/Contents/MacOS/$EXEC_NAME" --selftest "$2" ;;
  uninstall) pkill -x "$EXEC_NAME" 2>/dev/null || true; for a in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do [ -d "$a" ] && { rm -rf "$a"; ok "đã xóa $a"; }; done ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
