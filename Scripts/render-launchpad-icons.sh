#!/bin/bash
# Renders IrisinLaunchpad's icons into IrisinLaunchpad/Resources/Assets.xcassets:
# the Apple TV app icon (400x240 and its 2x, and the 1280x768 one the App
# Store would take) with the Top Shelf images, and the Apple Vision Pro icon.
# Both platforms want layers where iOS takes one picture, so the iOS icon's
# source, Documentation/Icon/AppIcon.icon, is taken apart: its fill is the
# back layer, the white box its one image is the front, and the middle is the
# box's shadow, which moves apart from it as the layers do. The fill is
# Icon Composer's automatic gradient of #0088FF, a lighter blue at the top
# reaching the colour itself three quarters of the way down, as the rendered
# iOS icon has it. The Top Shelf images set the name beside the box, in SF
# Rounded.
#
# Run it after editing the .icon; the catalog's Contents.json files name the
# files it writes and are not written here. Needs ImageMagick (`magick`).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v magick >/dev/null || { echo "error: ImageMagick's magick is required" >&2; exit 69; }

box="$root/Documentation/Icon/AppIcon.icon/Assets/AppIconTransparent.png"
font=/System/Library/Fonts/SFNSRounded.ttf
catalog="$root/IrisinLaunchpad/Resources/Assets.xcassets"
brand="$catalog/App Icon & Top Shelf Image.brandassets"
vision="$catalog/AppIcon.solidimagestack"
for file in "$box" "$font"; do
    [[ -f "$file" ]] || { echo "error: $file is missing" >&2; exit 66; }
done

top='#4AA9FF'
fill='#0088FF'

# The back layer: opaque, full bleed.
gradient() { # width height output
    local ramp=$(($2 * 3 / 4))
    magick -size "$1x$ramp" "gradient:$top-$fill" -size "$1x$(($2 - ramp))" "xc:$fill" -append \
        -strip -alpha off -define png:compression-level=9 "PNG24:$3"
}

# The front layer: the box `size` tall (or wide, `size` ending in x), centred.
front() { # width height size output
    magick -size "$1x$2" xc:none \( "$box" -resize "$3" \) -gravity center -composite \
        -strip -define png:compression-level=9 "PNG32:$4"
}

# The middle layer: the front layer's box as a soft shadow a little below it.
shadow() { # width height size output
    local sigma=$(($2 / 40 + 1)) drop=$(($2 / 50))
    magick -size "$1x$2" xc:none \
        \( "$box" -resize "$3" -channel RGB -evaluate set 0 +channel -channel A -evaluate multiply 0.35 +channel \) \
        -gravity center -geometry "+0+$drop" -composite -channel A -blur "0x$sigma" +channel \
        -strip -define png:compression-level=9 "PNG32:$4"
}

# One layered icon at one size: the box 60% of the height, where focus
# enlarging the icon keeps it clear of the edge.
tv_layers() { # imagestack width height file-name
    local stack="$brand/$1" boxh=$(($3 * 60 / 100))
    gradient "$2" "$3" "$stack/Back.imagestacklayer/Content.imageset/$4"
    shadow "$2" "$3" "x$boxh" "$stack/Middle.imagestacklayer/Content.imageset/$4"
    front "$2" "$3" "x$boxh" "$stack/Front.imagestacklayer/Content.imageset/$4"
}

# A Top Shelf image: the box and the name side by side, centred on the fill.
top_shelf() { # imageset width height file-name
    local boxh=$(($3 * 42 / 100)) points=$(($3 * 34 / 100)) gap=$(($3 * 9 / 100))
    local stroke=$((points / 36 + 1)) output="$brand/$1/$4"
    gradient "$2" "$3" "$output"
    magick "$output" \
        \( \( "$box" -resize "x$boxh" \) \
           \( -background none -fill white -stroke white -strokewidth "$stroke" -font "$font" \
              -pointsize "$points" label:Irisin -trim +repage \) \
           -background none -gravity center +smush "$gap" \) \
        -gravity center -composite -strip -alpha off -define png:compression-level=9 "PNG24:$output"
}

tv_layers "App Icon.imagestack" 400 240 Layer.png
tv_layers "App Icon.imagestack" 800 480 Layer@2x.png
tv_layers "App Icon - App Store.imagestack" 1280 768 Layer.png
top_shelf "Top Shelf Image.imageset" 1920 720 TopShelf.png
top_shelf "Top Shelf Image.imageset" 3840 1440 TopShelf@2x.png
top_shelf "Top Shelf Image Wide.imageset" 2320 720 TopShelfWide.png
top_shelf "Top Shelf Image Wide.imageset" 4640 1440 TopShelfWide@2x.png

# Apple Vision Pro masks the icon to a circle: the box 60% of its width,
# centred, keeps its corners well inside it.
gradient 1024 1024 "$vision/Back.solidimagestacklayer/Content.imageset/Layer.png"
shadow 1024 1024 614x "$vision/Middle.solidimagestacklayer/Content.imageset/Layer.png"
front 1024 1024 614x "$vision/Front.solidimagestacklayer/Content.imageset/Layer.png"
