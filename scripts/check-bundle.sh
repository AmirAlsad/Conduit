#!/bin/bash
# Usage: scripts/check-bundle.sh <path-to-Conduit.app>
#
# Static guard for the rule in bugs.md: a second un-prefixed WebRTC next to the
# one embedded in Daily's framework duplicates its RTC* ObjC classes and crashes
# every Daily call. Fails if Frameworks/ contains WebRTC.framework, or if any
# un-prefixed RTC* Objective-C class is defined in more than one Mach-O image.
set -u

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <path-to-.app>" >&2
  exit 2
fi

APP="${1%/}"
FW="$APP/Frameworks"
status=0

echo "Embedded frameworks in $FW:"
if [ -d "$FW" ]; then
  ls -1 "$FW" | sed 's/^/  /'
else
  echo "  (none)"
fi

if [ -d "$FW/WebRTC.framework" ]; then
  echo "FAIL: Frameworks/WebRTC.framework is embedded (stasel/Google WebRTC collides with Daily's WebRTC)."
  status=1
fi

# Collect Mach-O images: the app binary plus each framework binary.
images=()
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)
[ -n "$exe" ] && [ -f "$APP/$exe" ] && images+=("$APP/$exe")
for d in "$APP"/*.dylib; do
  [ -f "$d" ] && images+=("$d")
done
if [ -d "$FW" ]; then
  for f in "$FW"/*.framework; do
    [ -d "$f" ] || continue
    fexe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$f/Info.plist" 2>/dev/null)
    [ -z "$fexe" ] && fexe=$(basename "$f" .framework)
    [ -f "$f/$fexe" ] && images+=("$f/$fexe")
  done
fi

# Defined ObjC classes are "_OBJC_CLASS_$_Name" symbols placed in an __objc_data
# section. Daily statically links WebRTC with hidden visibility, so most of its
# RTC* classes are non-external: `nm -m` lists them, `nm -g` would miss them.
# Un-prefixed means RTC*, not the LKRTC* of LiveKitWebRTC.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for img in "${images[@]}"; do
  nm -m "$img" 2>/dev/null \
    | grep -E '__objc_data\).*_OBJC_CLASS_\$_RTC' \
    | sed -E 's/.*_OBJC_CLASS_\$_//' \
    | sort -u \
    | sed "s|^|$img\t|" >> "$tmp"
done

dups=$(cut -f2 "$tmp" | sort | uniq -d)
if [ -n "$dups" ]; then
  echo "FAIL: un-prefixed RTC* classes defined in more than one image:"
  while read -r cls; do
    [ -n "$cls" ] || continue
    echo "  $cls"
    awk -F'\t' -v c="$cls" '$2==c {print "    in " $1}' "$tmp"
  done <<< "$dups"
  status=1
fi

total=$(cut -f2 "$tmp" | sort -u | wc -l | tr -d ' ')
echo "Scanned ${#images[@]} Mach-O images; $total distinct un-prefixed RTC* classes defined."

if [ $status -eq 0 ]; then
  echo "OK"
fi
exit $status
