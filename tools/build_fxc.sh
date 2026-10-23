#!/usr/bin/env bash
# Builds ReShade's own effect compiler (tools/fxc.cpp) on Linux, so the shader can be
# checked with the exact front end ReShade uses in-game.
# Usage: tools/build_fxc.sh [work_dir]     (default: build)
set -euo pipefail

# Pinned to a commit after v6.8.0: the v6.8.0 tag's fxc tool passes --invert-y to the
# wrong GLSL code generator argument.
RESHADE_REF="${RESHADE_REF:-7bf9de8b33bcc76c3177007e65d73c72dd0f34c0}"
RESHADE_VERSION="${RESHADE_VERSION:-6.8.0}"
WORK="${1:-build}"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d reshade ]; then
    git init --quiet reshade
    git -C reshade fetch --quiet --depth 1 https://github.com/crosire/reshade.git "$RESHADE_REF"
    git -C reshade -c advice.detachedHead=false checkout --quiet FETCH_HEAD
fi
[ -d reshade-shaders ] || git clone --quiet --depth 1 --branch slim https://github.com/crosire/reshade-shaders.git reshade-shaders

ver="$RESHADE_VERSION"
IFS=. read -r major minor rev <<< "$ver"
cat > version.h <<EOF
#define VERSION_MAJOR ${major}
#define VERSION_MINOR ${minor}
#define VERSION_REVISION ${rev:-0}
#define VERSION_STRING_PRODUCT "${ver}"
EOF

# The DXBC and SPIR-V back ends need Windows/SPIRV-Tools; HLSL and GLSL output are enough here.
cat > stubs.cpp <<'EOF'
#include "effect_codegen.hpp"
namespace reshadefx {
codegen *create_codegen_dxbc(unsigned int, bool, bool, int) { return nullptr; }
codegen *create_codegen_spirv(bool, bool, bool, bool, bool) { return nullptr; }
}
EOF

S=reshade/source
g++ -std=c++20 -O1 -w -I. -I"$S" -Ireshade/include \
    "$S/effect_expression.cpp" "$S/effect_lexer.cpp" "$S/effect_parser_exp.cpp" \
    "$S/effect_parser_stmt.cpp" "$S/effect_preprocessor.cpp" "$S/effect_symbol_table.cpp" \
    "$S/effect_codegen_hlsl.cpp" "$S/effect_codegen_glsl.cpp" \
    reshade/tools/fxc.cpp stubs.cpp -o fxc

echo "Built ReShade FX compiler $(./fxc --version)"
