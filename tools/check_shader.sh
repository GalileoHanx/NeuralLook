#!/usr/bin/env bash
# Compiles NeuralLook.fx in every supported configuration with ReShade's compiler.
# Usage: tools/check_shader.sh [work_dir]     (run tools/build_fxc.sh first)
set -uo pipefail

WORK="${1:-build}"
FXC="$WORK/fxc"
INC="$WORK/reshade-shaders/Shaders"
FX="$(dirname "$0")/../Shaders/NeuralLook.fx"
failed=0

check() {
    local label="$1"; shift
    if "$FXC" -I "$INC" "$@" -Fo /dev/null "$FX"; then
        printf '  ok    %s\n' "$label"
    else
        printf '  FAIL  %s\n' "$label"
        failed=1
    fi
}

for res in "1280 720" "1920 1080" "2560 1440" "3840 2160"; do
    set -- $res
    echo "Resolution $1x$2"
    check "DirectX 10-12 (SM5)"          --hlsl --shader-model 50 --width "$1" --height "$2"
    check "DirectX 9 (SM3)"              --hlsl --shader-model 30 --width "$1" --height "$2"
    check "OpenGL / Vulkan (GLSL)"       --glsl --width "$1" --height "$2"
done

echo "Preprocessor switches (1080p, SM5)"
check "NL_CONTACT_SHADOWS=0"            --hlsl --width 1920 --height 1080 -D NL_CONTACT_SHADOWS=0
check "NL_SKIN=0"                       --hlsl --width 1920 --height 1080 -D NL_SKIN=0
check "NL_AO_SAMPLES=4"                 --hlsl --width 1920 --height 1080 -D NL_AO_SAMPLES=4
check "NL_AO_SAMPLES=12"                --hlsl --width 1920 --height 1080 -D NL_AO_SAMPLES=12
check "both optional phases off"        --hlsl --width 1920 --height 1080 -D NL_CONTACT_SHADOWS=0 -D NL_SKIN=0
check "HDR colour space warning path"   --hlsl --width 1920 --height 1080 -D BUFFER_COLOR_SPACE=2

if [ "$failed" -ne 0 ]; then
    echo "Some configurations failed to compile."
    exit 1
fi
echo "All configurations compiled."
