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
# Run the technique pass by pass
# --------------------------------------------------------------------------------------
ctx = moderngl.create_standalone_context(backend="egl", require=430)
head, body = open(glsl_path).read().split("\n", 1)


def program(entry):
    return ctx.program(vertex_shader=f"{head}\n#define E_xPostProcessVS\n{body}",
                       fragment_shader=f"{head}\n#define E_x{entry}\n{body}")


def texture(w, h, comps, dtype, data=None):
    t = ctx.texture((w, h), comps, data, dtype=dtype)
    t.filter = (moderngl.LINEAR, moderngl.LINEAR)
    t.repeat_x = t.repeat_y = False
    return t


hw, hh, qw, qh = W // 2, H // 2, W // 4, H // 4
tex = {
    "Back": texture(W, H, 4, "f1", np.dstack([color8, np.full((H, W), 255, np.uint8)]).tobytes()),
    "Depth": texture(W, H, 1, "f4", stored_depth.tobytes()),
    "Half": texture(hw, hh, 4, "f2"), "BlurA": texture(hw, hh, 4, "f2"), "Small": texture(hw, hh, 4, "f2"),
    "Quart": texture(qw, qh, 4, "f2"), "QBlurA": texture(qw, qh, 4, "f2"), "Large": texture(qw, qh, 4, "f2"),
    "AO": texture(hw, hh, 1, "f2"), "AOBlur": texture(hw, hh, 1, "f2"),
}
final = texture(W, H, 4, "f1")
bindings = ["Back", "Depth", "Half", "BlurA", "Small", "Quart", "QBlurA", "Large", "AO", "AOBlur"]
passes = [("PS_NL_Down", "Half"), ("PS_NL_SmallH", "BlurA"), ("PS_NL_SmallV", "Small"),
          ("PS_NL_DownQ", "Quart"), ("PS_NL_LargeH", "QBlurA"), ("PS_NL_LargeV", "Large"),
          ("PS_NL_AO", "AO"), ("PS_NL_AOBlurH", "AOBlur"), ("PS_NL_AOBlurV", "AO"),
          ("PS_NL_Composite", None)]
programs = {entry: program(entry) for entry, _ in passes}
ubo = ctx.buffer(reserve=80)
ubo.bind_to_uniform_block(0)


def render(preset=2, master=1.0, compare=False, split=0.5, debug=0):
    # Uniform block in declaration order (std140, all 4-byte scalars)
    data = struct.pack("<i13fIfi", preset, master, 0.45, 0.40, 0.35, 0.25, 0.10, 0.55, 0.40, 0.35,
                       0.5, 0.3, 70.0, 1.0, int(compare), split, debug)
    ubo.write(data + b"\0" * (80 - len(data)))
    for entry, target in passes:
        out = final if target is None else tex[target]
        for unit, name in enumerate(bindings):
            tex[name].use(unit)
        fbo = ctx.framebuffer([out])
        fbo.use()
        ctx.viewport = (0, 0, out.width, out.height)
        vao = ctx.vertex_array(programs[entry], [])
        vao.render(moderngl.TRIANGLES, vertices=3)
        vao.release()
        fbo.release()
    return np.frombuffer(final.read(), np.uint8).reshape(H, W, 4)[..., :3].copy()


runs = {"light": dict(preset=1), "balanced": dict(preset=2), "strong": dict(preset=3),
        "strength_zero": dict(master=0.0), "debug_contact_shadows": dict(debug=1),
        "debug_skin_mask": dict(debug=2), "debug_lighting_contrast": dict(debug=3),
        "split_compare": dict(compare=True)}
img = {}
for name, kw in runs.items():
    img[name] = render(**kw)
    Image.fromarray(img[name]).save(os.path.join(OUT, f"{name}.png"))

# Side-by-side close-up: original | balanced | strong
box = (340, 170, 720, 460)
strip = Image.new("RGB", (3 * 380 + 16, 290 + 34), (18, 18, 18))
for i, (name, label) in enumerate([("original", "Original"), ("balanced", "Balanced"), ("strong", "Strong")]):
    src = Image.fromarray(color8) if name == "original" else Image.fromarray(img[name])
    strip.paste(src.crop(box), (i * 388, 34))
    ImageDraw.Draw(strip).text((i * 388 + 8, 10), label, fill=(235, 235, 235))
strip.save(os.path.join(OUT, "comparison.png"))

# --------------------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------------------
src = color8.astype(np.float32)
failures = []


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


print(f"Renderer: {ctx.info['GL_RENDERER']}")
diffs = {k: np.abs(img[k].astype(np.float32) - src).mean() for k in ("light", "balanced", "strong")}
check(np.abs(img["strength_zero"].astype(np.float32) - src).max() <= 1.0, "Overall strength 0 returns the original image")
check(diffs["light"] > 1.0, f"Light preset changes the image (mean diff {diffs['light']:.2f})")
check(diffs["light"] < diffs["balanced"] < diffs["strong"],
      f"Presets get stronger in order ({diffs['light']:.2f} < {diffs['balanced']:.2f} < {diffs['strong']:.2f})")
holes = int(((img["balanced"].max(-1) == 0) & (color8.max(-1) > 30)).sum())
check(holes == 0, f"No black (NaN) pixels ({holes})")
clipped = (img["balanced"].max(-1) >= 255).mean() * 100
check(clipped < 2.0, f"Balanced clips under 2% of pixels ({clipped:.2f}%)")

occ = 1.0 - img["debug_contact_shadows"][..., 0] / 255.0
check(occ[:int(H * 0.05)].max() < 0.01, "No contact shadows in the sky")
check(occ[int(H * 0.88):int(H * 0.95), int(W * 0.05):int(W * 0.25)].mean() < 0.02, "No shadows on open, flat floor")
check(occ[int(H * 0.55):int(H * 0.75)].max() > 0.15, f"Contact shadows where objects touch the floor (max {occ[int(H * 0.55):int(H * 0.75)].max():.2f})")

mask = img["debug_skin_mask"].astype(np.float32)
skin = (mask[..., 0] - mask[..., 1]) > 60
check(skin[obj == 0].mean() > 0.9, f"Skin detected on the head, lit and shadowed side ({skin[obj == 0].mean() * 100:.0f}%)")
check(skin[obj == 1].mean() < 0.05, f"Grey ball not treated as skin ({skin[obj == 1].mean() * 100:.0f}%)")
check(skin[sky].mean() < 0.01, "Sky not treated as skin")
print(f"  info  Brick wall treated as skin: {skin[obj == 4].mean() * 100:.0f}% (known limitation, colour-only detection)")

print(f"Images saved to {OUT}")
if failures:
    sys.exit(1)
