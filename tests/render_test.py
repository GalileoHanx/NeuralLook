"""Render test for NeuralLook.fx.

Compiles the shader to GLSL with ReShade's own compiler, then runs every pass in
technique order on a synthetic scene with Mesa's OpenGL driver (no GPU needed).
Saves the images and fails if basic sanity checks don't hold.

Usage: python3 tests/render_test.py [work_dir]   (run tools/build_fxc.sh first)
"""
import os
import struct
import subprocess
import sys

import moderngl
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build"))
OUT = os.path.join(WORK, "render")
FX = os.path.join(ROOT, "Shaders", "NeuralLook.fx")
W, H, FAR = 1280, 720, 1000.0
os.makedirs(OUT, exist_ok=True)

# --------------------------------------------------------------------------------------
# Compile with ReShade's compiler (GLSL, Y-flipped for render-to-texture)
# --------------------------------------------------------------------------------------
glsl_path = os.path.join(WORK, "neurallook_test.glsl")
subprocess.run([os.path.join(WORK, "fxc"), "--glsl", "--invert-y", "--width", str(W), "--height", str(H),
                "-I", os.path.join(WORK, "reshade-shaders", "Shaders"), "-Fo", glsl_path, FX], check=True)

# --------------------------------------------------------------------------------------
# Synthetic scene: a skin-toned head, a grey ball and a wooden ball resting on a tiled
# floor in front of a brick wall. Ray cast in numpy, with reversed depth like most games.
# --------------------------------------------------------------------------------------
th = np.tan(np.radians(70.0) / 2)
ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
dirs = np.stack([((xs + 0.5) / W * 2 - 1) * th * (W / H), -((ys + 0.5) / H * 2 - 1) * th, np.ones_like(xs)], -1)
dirs /= np.linalg.norm(dirs, axis=-1, keepdims=True)
rng = np.random.default_rng(1)


def noise2(u, v, scale):
    g = rng.random((64, 64)).astype(np.float32)
    return g[(np.floor(v * scale) % 64).astype(int), (np.floor(u * scale) % 64).astype(int)]


t_best = np.full((H, W), np.inf, np.float32)
obj = np.full((H, W), -1, np.int32)
normal = np.zeros((H, W, 3), np.float32)
for centre, radius, sid in [(np.array([-0.9, 0.0, 5.0]), 1.0, 0),
                            (np.array([1.5, -0.45, 4.2]), 0.55, 1),
                            (np.array([0.55, -0.7, 3.2]), 0.3, 2)]:
    oc = -centre
    b = (dirs * oc).sum(-1)
    disc = b * b - ((oc * oc).sum() - radius * radius)
    t = -b - np.sqrt(np.maximum(disc, 0))
    hit = (disc > 0) & (t > 0) & (t < t_best)
    t_best[hit], obj[hit] = t[hit], sid
    normal[hit] = (dirs[hit] * t[hit, None] - centre) / radius
t = -1.0 / np.where(dirs[..., 1] < -1e-4, dirs[..., 1], -1e-4)
hit = (dirs[..., 1] < -1e-4) & (t < t_best) & (t < 40)
t_best[hit], obj[hit], normal[hit] = t[hit], 3, [0, 1, 0]
t = 12.0 / dirs[..., 2]
hit = (t < t_best) & (dirs[..., 1] * t < 4)
t_best[hit], obj[hit], normal[hit] = t[hit], 4, [0, 0, -1]

pos = dirs * np.where(np.isinf(t_best), 0, t_best)[..., None]
light = np.array([-0.5, 0.75, -0.45]); light /= np.linalg.norm(light)
half = light - dirs; half /= np.linalg.norm(half, axis=-1, keepdims=True)
ndl = np.clip((normal * light).sum(-1), 0, 1)
ndh = np.clip((normal * half).sum(-1), 0, 1)

albedo = np.zeros((H, W, 3), np.float32)
spec = np.zeros((H, W), np.float32)
m = obj == 0; albedo[m] = [0.62, 0.38, 0.28]; albedo[m] += (noise2(xs, ys, 1.0)[m] * 0.06 - 0.03)[:, None]; spec[m] = 0.35
m = obj == 1; albedo[m] = 0.5; spec[m] = 0.5
m = obj == 2; albedo[m] = np.array([0.45, 0.26, 0.11]) * (0.85 + 0.15 * np.sin(pos[m][:, 1] * 60))[:, None]; spec[m] = 0.2
m = obj == 3
tile = (np.floor(pos[m][:, 0] * 1.5) + np.floor(pos[m][:, 2] * 1.5)) % 2
albedo[m] = (0.35 + 0.1 * tile + noise2(pos[m][:, 0], pos[m][:, 2], 20) * 0.08)[:, None] * [0.9, 0.95, 1.0]
m = obj == 4
mortar = (np.abs((pos[m][:, 1] * 4) % 1 - 0.5) > 0.45) | \
         (np.abs((pos[m][:, 0] * 2 + 0.5 * np.floor(pos[m][:, 1] * 4)) % 1 - 0.5) > 0.47)
albedo[m] = np.where(mortar[:, None], [0.55, 0.55, 0.52], [0.42, 0.22, 0.17]) * \
            (0.9 + noise2(pos[m][:, 0], pos[m][:, 1], 30)[:, None] * 0.2)

lin = albedo * (0.18 + 0.9 * ndl[..., None]) + spec[..., None] * ndh[..., None] ** 40
sky = obj < 0
lin[sky] = np.stack([0.45 + 0.2 * (1 - ys[sky] / H), 0.6 + 0.2 * (1 - ys[sky] / H), np.full(sky.sum(), 0.85)], -1)
color8 = (np.clip(lin, 0, 1) ** (1 / 2.2) * 255 + 0.5).astype(np.uint8)

lin_depth = np.where(sky, 1.0, t_best * dirs[..., 2] / FAR).astype(np.float32)
stored_depth = (1 - lin_depth * FAR / (1 + lin_depth * (FAR - 1))).astype(np.float32)  # reversed depth
Image.fromarray(color8).save(os.path.join(OUT, "original.png"))

# --------------------------------------------------------------------------------------
# Read uniform defaults from the .fx file, and the uniform/sampler layout from the GLSL
# --------------------------------------------------------------------------------------
import re

fx_src = open(FX).read()
defaults = {}
for m in re.finditer(r"uniform\s+(int|float|bool)\s+(\w+)\s*<(.*?)>\s*(?:=\s*([^;]+))?;", fx_src, re.S):
    kind, name, _, value = m.groups()
    value = (value or "0").strip()
    if kind == "bool":
        defaults[name] = value == "true"
    elif kind == "int":
        defaults[name] = int(value)
    else:
        defaults[name] = float(value)

glsl_src = open(glsl_path).read()
ubo_block = re.search(r"uniform _Globals \{(.*?)\};", glsl_src, re.S).group(1)
ubo_layout = re.findall(r"\b(int|uint|float|bool)\s+V_x(\w+);", ubo_block)
sampler_layout = {name: int(b) for b, name in
                  re.findall(r"layout\(binding = (\d+)\) uniform sampler2D V_x(\w+);", glsl_src)}
unknown = [n for _, n in ubo_layout if n not in defaults]
assert not unknown, f"uniforms missing from defaults: {unknown}"


def pack_uniforms(values):
    out = b""
    for kind, name in ubo_layout:  # std140: every scalar is 4 bytes, 4-byte aligned
        v = values[name]
        out += struct.pack("<f", v) if kind == "float" else struct.pack("<i", int(v))
    return out + b"\0" * (-len(out) % 16)


# --------------------------------------------------------------------------------------
# Run the technique pass by pass
# --------------------------------------------------------------------------------------
ctx = moderngl.create_standalone_context(backend="egl", require=430)
head, body = glsl_src.split("\n", 1)


def program(entry):
    return ctx.program(vertex_shader=f"{head}\n#define E_xPostProcessVS\n{body}",
                       fragment_shader=f"{head}\n#define E_x{entry}\n{body}")


def texture(w, h, comps, dtype, data=None, nearest=False):
    t = ctx.texture((w, h), comps, data, dtype=dtype)
    f = moderngl.NEAREST if nearest else moderngl.LINEAR
    t.filter = (f, f)
    t.repeat_x = t.repeat_y = False
    return t


font = Image.open(os.path.join(WORK, "reshade-shaders", "Textures", "FontAtlas.png")).convert("RGBA")
hw, hh, qw, qh = W // 2, H // 2, W // 4, H // 4
depth_real = stored_depth.tobytes()
depth_blank = np.zeros((H, W), np.float32).tobytes()  # what ReShade binds when it finds no depth
tex = {
    "ReShade_xBackBuffer": texture(W, H, 4, "f1", np.dstack([color8, np.full((H, W), 255, np.uint8)]).tobytes()),
    "ReShade_xDepthBuffer": texture(W, H, 1, "f4", depth_real),
    "NL_Half": texture(hw, hh, 4, "f2"), "NL_BlurA": texture(hw, hh, 4, "f2"), "NL_Small": texture(hw, hh, 4, "f2"),
    "NL_Quart": texture(qw, qh, 4, "f2"), "NL_QBlurA": texture(qw, qh, 4, "f2"), "NL_Large": texture(qw, qh, 4, "f2"),
    "NL_AO": texture(hw, hh, 1, "f2"), "NL_AOBlur": texture(hw, hh, 1, "f2"),
    "NL_State": texture(1, 1, 1, "f2", nearest=True), "NL_StatePrev": texture(1, 1, 1, "f2", nearest=True),
    "samplerText": texture(512, 512, 4, "f1", font.resize((512, 512)).tobytes()),
}
missing = [n for n in sampler_layout if n not in tex]
assert not missing, f"no test texture for samplers: {missing}"
final = texture(W, H, 4, "f1")
passes = [("PS_NL_Down", "NL_Half"), ("PS_NL_SmallH", "NL_BlurA"), ("PS_NL_SmallV", "NL_Small"),
          ("PS_NL_DownQ", "NL_Quart"), ("PS_NL_LargeH", "NL_QBlurA"), ("PS_NL_LargeV", "NL_Large"),
          ("PS_NL_DepthCheck", "NL_State"), ("PS_NL_StateCopy", "NL_StatePrev"),
          ("PS_NL_AO", "NL_AO"), ("PS_NL_AOBlurH", "NL_AOBlur"), ("PS_NL_AOBlurV", "NL_AO"),
          ("PS_NL_Composite", None)]
programs = {entry: program(entry) for entry, _ in passes}
ubo = ctx.buffer(reserve=max(16, len(pack_uniforms(defaults))))
ubo.bind_to_uniform_block(0)


def set_depth(real):
    tex["ReShade_xDepthBuffer"].write(depth_real if real else depth_blank)


def set_state(v):
    for n in ("NL_State", "NL_StatePrev"):
        tex[n].write(np.array([v], np.float16).tobytes())


def read_state():
    return float(np.frombuffer(tex["NL_State"].read(), np.float16)[0])


def render(**overrides):
    values = dict(defaults)
    values.update(overrides)
    ubo.write(pack_uniforms(values))
    for entry, target in passes:
        out = final if target is None else tex[target]
        for name, unit in sampler_layout.items():
            tex[name].use(unit)
        fbo = ctx.framebuffer([out])
        fbo.use()
        ctx.viewport = (0, 0, out.width, out.height)
        vao = ctx.vertex_array(programs[entry], [])
        vao.render(moderngl.TRIANGLES, vertices=3)
        vao.release()
        fbo.release()
    return np.frombuffer(final.read(), np.uint8).reshape(H, W, 4)[..., :3].copy()


img = {}


def shot(name, **kw):
    img[name] = render(**kw)
    Image.fromarray(img[name]).save(os.path.join(OUT, f"{name}.png"))
    return img[name]


# Depth detection: one frame from each starting state
set_depth(True); set_state(0.0); render()
state_rises = read_state()
set_depth(False); set_state(1.0); render()
state_falls = read_state()

# Game with depth (state settled at 1)
set_depth(True); set_state(1.0)
shot("light", NL_Preset=1); shot("balanced", NL_Preset=2); shot("strong", NL_Preset=3)
shot("classic", NL_Preset=4)
shot("strength_zero", NL_Master=0.0)
shot("debug_shadows", NL_Debug=1); shot("debug_skin_mask", NL_Debug=2); shot("debug_lighting_contrast", NL_Debug=3)
shot("split_compare", NL_Compare=True)
shot("glow_off", NL_Glow=0.0)
shot("lens_vignette", NL_Vignette=1.0)
shot("grain_frame0", NL_Grain=1.0, NL_Frame=0); shot("grain_frame7", NL_Grain=1.0, NL_Frame=7)
moods = ["neutral", "cinematic_warm", "survival_horror", "teal_orange", "golden_hour", "cold_night"]
for k, mood in enumerate(moods):
    shot(f"mood_{mood}", NL_Mood=k, NL_MoodStrength=1.0)
shot("status_depth", NL_OverlayOpen=True)

# Game without depth, like Resident Evil 0 (state settled at 0)
set_depth(False); set_state(0.0)
shot("nodepth_balanced", NL_Preset=2)
shot("nodepth_classic", NL_Preset=4)
shot("nodepth_debug_shadows", NL_Debug=1)
shot("status_nodepth", NL_OverlayOpen=True)

# Side-by-side close-up: original | balanced | strong
box = (340, 170, 720, 460)
strip = Image.new("RGB", (3 * 380 + 16, 290 + 34), (18, 18, 18))
for i, (name, label) in enumerate([("original", "Original"), ("balanced", "Balanced"), ("strong", "Strong")]):
    src_img = Image.fromarray(color8) if name == "original" else Image.fromarray(img[name])
    strip.paste(src_img.crop(box), (i * 388, 34))
    ImageDraw.Draw(strip).text((i * 388 + 8, 10), label, fill=(235, 235, 235))
strip.save(os.path.join(OUT, "comparison.png"))

# Mood grid
grid = Image.new("RGB", (3 * 427, 2 * 240 + 2 * 26), (18, 18, 18))
for k, mood in enumerate(moods):
    x, y = (k % 3) * 427, (k // 3) * 266
    grid.paste(Image.fromarray(img[f"mood_{mood}"]).resize((427, 240)), (x, y + 26))
    ImageDraw.Draw(grid).text((x + 8, y + 7), mood.replace("_", " ").capitalize(), fill=(235, 235, 235))
grid.save(os.path.join(OUT, "moods.png"))

# --------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------
src = color8.astype(np.float32)
failures = []


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def meandiff(a, b):
    return float(np.abs(a.astype(np.float32) - b.astype(np.float32)).mean())


print(f"Renderer: {ctx.info['GL_RENDERER']}")
print("Core look")
diffs = {k: meandiff(img[k], src) for k in ("light", "balanced", "strong")}
check(np.abs(img["strength_zero"].astype(np.float32) - src).max() <= 1.0, "Overall strength 0 returns the original image")
check(diffs["light"] > 1.0, f"Light preset changes the image (mean diff {diffs['light']:.2f})")
check(diffs["light"] < diffs["balanced"] < diffs["strong"],
      f"Presets get stronger in order ({diffs['light']:.2f} < {diffs['balanced']:.2f} < {diffs['strong']:.2f})")
check(meandiff(img["classic"], img["balanced"]) > 1.0, "Classic games preset differs from Balanced")
holes = int(((img["balanced"].max(-1) == 0) & (color8.max(-1) > 30)).sum())
check(holes == 0, f"No black (NaN) pixels ({holes})")
clipped = (img["balanced"].max(-1) >= 255).mean() * 100
check(clipped < 2.0, f"Balanced clips under 2% of pixels ({clipped:.2f}%)")

print("Depth detection")
check(state_rises > 0.02, f"Real depth raises the depth flag ({state_rises:.3f} after one frame)")
check(state_falls < 0.98, f"Blank depth lowers the depth flag ({state_falls:.3f} after one frame)")

print("Shadows")
occ = 1.0 - img["debug_shadows"][..., 0] / 255.0
check(occ[:int(H * 0.05)].max() < 0.01, "No shadows in the sky")
check(occ[int(H * 0.88):int(H * 0.95), int(W * 0.05):int(W * 0.25)].mean() < 0.02, "No shadows on open, flat floor")
contact = occ[int(H * 0.55):int(H * 0.75)].max()
check(contact > 0.10, f"Contact shadows where objects touch the floor (max {contact:.2f})")
occ_nd = 1.0 - img["nodepth_debug_shadows"][..., 0] / 255.0
check(occ_nd.max() > 0.1, f"Without depth, depth-free shadows take over (max {occ_nd.max():.2f})")
check(meandiff(img["nodepth_balanced"], src) > 1.0, "Without depth, the look still applies")

print("Skin")
mask = img["debug_skin_mask"].astype(np.float32)
skin = (mask[..., 0] - mask[..., 1]) > 60
check(skin[obj == 0].mean() > 0.9, f"Skin detected on the head, lit and shadowed side ({skin[obj == 0].mean() * 100:.0f}%)")
check(skin[obj == 1].mean() < 0.05, f"Grey ball not treated as skin ({skin[obj == 1].mean() * 100:.0f}%)")
check(skin[sky].mean() < 0.01, "Sky not treated as skin")
print(f"  info  Brick wall treated as skin: {skin[obj == 4].mean() * 100:.0f}% (known limitation, colour-only detection)")

print("Mood and lens")
neutral = img["mood_neutral"].astype(np.float32)
for mood in moods[1:]:
    check(meandiff(img[f"mood_{mood}"], neutral) > 2.0, f"Mood '{mood}' changes the image ({meandiff(img[f'mood_{mood}'], neutral):.1f})")


colourful = (obj == 0) | (obj == 2) | (obj == 4)  # skin, wood, brick


def saturation(a):
    a = a.astype(np.float32)
    return float((a.max(-1) - a.min(-1))[colourful].mean())


def warmth(a):
    a = a.astype(np.float32)
    return float((a[..., 0] - a[..., 2]).mean())


check(saturation(img["mood_survival_horror"]) < saturation(neutral), "Survival horror mutes colourful surfaces (skin, wood, brick)")
check(warmth(img["mood_golden_hour"]) > warmth(neutral) > warmth(img["mood_cold_night"]),
      "Golden hour is warmer and cold night cooler than neutral")
check(meandiff(img["glow_off"], img["balanced"]) > 0.2, "Light glow changes the image")
corner = img["lens_vignette"][:40, :40].astype(np.float32).mean() / img["balanced"][:40, :40].astype(np.float32).mean()
check(corner < 0.9, f"Vignette darkens the corners (to {corner * 100:.0f}%)")
check(meandiff(img["grain_frame0"], img["grain_frame7"]) > 0.5, "Film grain moves between frames")

print("Status badge")
badge = (slice(12, 102), slice(12, 410))
check(meandiff(img["status_depth"][badge], img["balanced"][badge]) > 20, "Badge appears while the menu is open")
check(meandiff(img["status_depth"][200:, 500:], img["balanced"][200:, 500:]) < 0.01, "Badge leaves the rest of the screen alone")
g = img["status_depth"][badge].astype(np.float32)
a = img["status_nodepth"][badge].astype(np.float32)
check(((g[..., 1] - g[..., 0]) > 60).sum() > 50, "With depth, the status line is green")
check((((a[..., 0] - a[..., 2]) > 80) & (a[..., 0] > 150)).sum() > 50, "Without depth, the status line is amber")

print(f"Images saved to {OUT}")
if failures:
    sys.exit(1)
