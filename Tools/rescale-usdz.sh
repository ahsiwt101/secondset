#!/bin/bash
# Rescale a captured USDZ to its true physical size.
#
#   Tools/rescale-usdz.sh <input.usdz> <true-longest-dimension-cm> [output.usdz]
#
# Why this matters: ObjectTrackingProvider matches against real-world
# dimensions. A model that is 4x too large trains a tracker that spends the
# whole case looking for a 1-metre Vision Pro and never finds the real one.
# Photogrammetry without a scale reference routinely produces models that look
# perfect and are sized wrong, and nothing downstream will warn you.
#
# Measure the object's longest side with a ruler. That single number is enough:
# the scale is uniform, so fixing one axis fixes all three.

set -euo pipefail

IN="${1:?usage: rescale-usdz.sh <input.usdz> <true-longest-cm> [output.usdz]}"
TRUE_CM="${2:?need the true longest dimension in cm}"
OUT="${3:-${IN%.usdz}-scaled.usdz}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IN" -d "$WORK"
MODEL="$(find "$WORK" -maxdepth 1 \( -name '*.usdc' -o -name '*.usda' \) | head -1)"
[ -n "$MODEL" ] || { echo "no .usdc/.usda found inside $IN" >&2; exit 1; }

# Current bounding box, from the first mesh extent.
EXTENT=$(usdcat "$MODEL" | grep -oE "extent = \[\([-0-9.e, ]+\), \([-0-9.e, ]+\)\]" | head -1)
[ -n "$EXTENT" ] || { echo "could not read extent from $IN" >&2; exit 1; }

read -r CUR_M FACTOR <<EOF
$(python3 - "$EXTENT" "$TRUE_CM" <<'PY'
import re, sys
nums = [float(x) for x in re.findall(r'-?\d+\.?\d*(?:e-?\d+)?', sys.argv[1])]
mn, mx = nums[0:3], nums[3:6]
longest = max(hi - lo for lo, hi in zip(mn, mx))
true_m = float(sys.argv[2]) / 100.0
print(longest, true_m / longest if longest else 1.0)
PY
)
EOF

printf 'current longest: %.3f m   ->   true: %s cm   scale x%.4f\n' \
  "$CUR_M" "$TRUE_CM" "$FACTOR"

# Convert to text, apply a uniform scale on the root Xform, repackage.
usdcat -o "$WORK/_edit.usda" "$MODEL"
python3 - "$WORK/_edit.usda" "$FACTOR" <<'PY'
import re, sys
path, factor = sys.argv[1], float(sys.argv[2])
src = open(path).read()

# Find the root Xform, then its body brace. Naively matching the first "{"
# after the prim name lands inside the `assetInfo = { ... }` metadata block
# instead — the prim body brace is the first one at column 0.
m = re.search(r'^def Xform "[^"]+"', src, re.M)
if not m:
    sys.exit("no root Xform found — cannot apply scale")

brace = src.find('\n{\n', m.end())
if brace == -1:
    sys.exit("could not locate the root prim body")
insert_at = brace + 3

inject = (
    f'    float3 xformOp:scale = ({factor}, {factor}, {factor})\n'
    f'    uniform token[] xformOpOrder = ["xformOp:scale"]\n'
)
open(path, 'w').write(src[:insert_at] + inject + src[insert_at:])
PY

MODEL_NAME="$(basename "${MODEL%.*}")"
rm -f "$MODEL"
mv "$WORK/_edit.usda" "$WORK/$MODEL_NAME.usda"

# usdzip needs an absolute output path and the model file listed first.
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_ABS="$OUT_DIR/$(basename "$OUT")"
rm -f "$OUT_ABS"
( cd "$WORK" && usdzip "$OUT_ABS" "$MODEL_NAME.usda" $(ls -d */ 2>/dev/null) >/dev/null )

echo "wrote $OUT_ABS"
echo -n "verified new extent: "
usdcat "$OUT_ABS" | grep -oE "extent = \[\([-0-9.e, ]+\), \([-0-9.e, ]+\)\]" | head -1
