#!/bin/zsh
# Renders the app's own preview pictures (window pages, strip, ghost and chips) in both themes into <out>/light and
# <out>/dark, from a scratch copy built in a temp folder whose DrafterHome is an empty temp folder: made-up records only.
# Never installs, never starts or stops the live app, never reads data/. Usage: zsh scripts/look-preview.sh <out>
set -e
root=${0:A:h:h}; out=${1:?usage: look-preview.sh <out>}; out=${out:A}
tmp=$(mktemp -d -t drafter-look)
app=$tmp/Drafter.app
mkdir -p $tmp/home/data $app/Contents/MacOS $app/Contents/Resources
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.0 $root/app/*.swift -o $app/Contents/MacOS/Drafter
cp $root/app/Info.plist $app/Contents/
[[ -d $root/app/art ]] && cp -R $root/app/art $app/Contents/Resources/
/usr/libexec/PlistBuddy -c "Add :DrafterHome string $tmp/home" $app/Contents/Info.plist
for theme in light dark; do
  mkdir -p $out/$theme
  $app/Contents/MacOS/Drafter --ui-preview $out/$theme ${${theme:#light}:+--dark}
done
[[ -n $(ls $tmp/home/data) ]] && echo "scratch data written: $(ls $tmp/home/data | tr '\n' ' ')"
rm -rf $tmp
