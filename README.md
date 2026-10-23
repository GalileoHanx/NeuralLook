# NeuralLook

A ReShade shader that brings a neural-rendering-style look to older GPUs: richer lighting on faces and surfaces, more material detail, contact shadows, and warmer, less waxy skin. Built and tuned for the GTX 1650.

![Original, Balanced and Strong presets on the test scene](docs/images/comparison.png)
<sub>Synthetic test scene: original, Balanced preset, Strong preset. Game screenshots will be added after the Resident Evil testing round.</sub>

> **Status: v0.1.0, under testing.** Currently being tested in **Resident Evil 2** (2019) and **Resident Evil 0 HD Remaster** on a GTX 1650. Expect settings and presets to change.

---

## Why

NVIDIA's DLSS 5 Neural Rendering changes how lighting and materials look, especially on skin, hair and fabric, but it needs tensor cores. It costs a large share of the frame rate even on high-end cards, and it can't run at all on GTX cards such as the 1650 or 1660.

NeuralLook goes after the same kind of look with ordinary shader math, at a cost a GTX 1650 can afford. It is an imitation, not a port. No AI model runs, and no NVIDIA files are used or needed.

## What it does

| Phase | Effect | Needs depth? |
|---|---|---|
| 1. Core look | Local lighting contrast, adaptive material detail, highlights that pick up surface texture, a gentle filmic curve, vibrance | No |
| 2. Contact shadows | Small-radius shadows in creases, joints and where objects meet the ground | Yes |
| 3. Skin | Warm light wrap at the light/shadow edge (like subsurface scattering), redder shadowed skin, extra skin texture | No |
| 4. Tuning | Light / Balanced / Strong presets, split-screen compare, debug views | No |

Heavy work runs at half and quarter resolution. Phases 2 and 3 can be switched off completely to save performance.

![Contact shadow and skin mask debug views](docs/images/debug-views.png)

## What it doesn't do

- **It doesn't generate detail.** It only strengthens detail already in the frame. Low-resolution textures stay low resolution.
- **It doesn't recognise materials.** Skin is found by colour, so brick, wood and sand can be treated as skin. The Skin detection width slider and the Skin mask debug view help with this.
- **It doesn't relight the scene.** It can't add light that isn't there or fix wrong lighting.
- **It doesn't upscale or generate frames.** For that, pair it with your game's upscaler or a tool like OptiScaler (FSR/XeSS).
- **No HDR support yet.** Turn HDR off in the game.

## NeuralLook vs DLSS 5 Neural Rendering

| | NeuralLook | DLSS 5 Neural Rendering |
|---|---|---|
| How it works | Hand-written shaders on the final image, plus depth | AI model that re-shades lighting and materials from game data |
| GPUs | Anything ReShade runs on; tuned for GTX 1650 | RTX 50 officially; RTX 20–40 only through community mods |
| Performance cost | Light (being measured on GTX 1650) | Heavy: roughly half the frame rate in early reviews |
| Skin | Colour-based mask, light wrap, texture boost | Recognises skin, hair and fabric; adds subsurface scattering and pore detail |
| New detail | No, enhances what is there | Yes, generates lighting and material detail |
| Games | Most DirectX 9–12, OpenGL and Vulkan games ReShade supports | Games with official support, or others through mods |

DLSS 5 details come from public reviews such as [Notebookcheck](https://www.notebookcheck.net/First-DLSS-5-game-tested-DLSS-5-humbles-RTX-5090-with-over-50-performance-loss.1391978.0.html) and [TechSpot](https://techspot.com/article/3170-real-dlss-5-performance).

---

## How to use it (step by step)

### What you need

- Windows and a game that ReShade supports
- [ReShade](https://reshade.me) 5.0 or newer (the normal version is fine)
- `NeuralLook.fx` from the [Releases](../../releases) page or the `Shaders` folder of this repo

Don't use ReShade in online games with anti-cheat.

### 1. Install ReShade

1. Find the game's folder, the one containing its `.exe`. In Steam, right-click the game, then **Manage → Browse local files**.
2. Run the ReShade installer and select the game's `.exe`.
3. Choose the game's graphics API (for example DirectX 10/11/12, or Direct3D 9 for older games).
4. When it lists effect packages, keep **Standard effects** ticked. NeuralLook needs `ReShade.fxh` from that package, and `DisplayDepth.fx` is useful for checking depth.
5. Finish the installer.

### 2. Add NeuralLook

1. Copy `NeuralLook.fx` into the game folder, inside `reshade-shaders\Shaders\`.
2. Start the game. A ReShade banner appears at the top of the screen.
3. Press **Home** to open the ReShade menu, and skip the tutorial if it shows.

### 3. Check depth (for contact shadows)

1. In the effect list, tick **DisplayDepth**.
2. The depth view is right when near objects are dark, far objects are light, and the image is the right way up.
3. If it's upside down or inverted, click **Edit global preprocessor definitions** and flip `RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN` or `RESHADE_DEPTH_INPUT_IS_REVERSED` between 0 and 1.
4. If it's blank, open the **Add-ons** tab, then **Generic Depth**, and try another depth buffer from the list.
5. Untick DisplayDepth when it looks right. If you can't get depth working, set `NL_CONTACT_SHADOWS` to 0 (see step 6) and use everything else.

### 4. Turn it on

1. Tick **NeuralLook** in the effect list.
2. Set **Look preset** to **Balanced**.
3. Turn on **Split-screen compare**: the left side shows NeuralLook, the right side the original game. Drag **Split position** to move the line.
4. Find a well-lit scene with a character's face to judge it. Turn Split-screen compare off when you're done.

### 5. Tune it

- **Overall strength** scales everything, in any preset.
- To set each effect yourself, choose **Custom** and open the **Custom** sections.
- Set **Debug view** to **Contact shadows**, then adjust **Contact shadow radius** until the shadows sit in corners and under feet without forming dark halos. Set **Game vertical field of view** close to the game's.
- Set **Debug view** to **Skin mask**. If walls or wood show up red, lower **Skin detection width**.
- Set **Debug view** back to **Off**.

### 6. Check performance

1. Open the **Statistics** tab to see how many milliseconds NeuralLook takes.
2. In the **Settings** tab, set an effect toggle key so you can compare frame rates with it on and off.
3. If it's too heavy, open the preprocessor definitions at the bottom of NeuralLook's settings and change, in this order:
   - `NL_AO_SAMPLES` from 8 to 4
   - `NL_CONTACT_SHADOWS` to 0
   - `NL_SKIN` to 0

ReShade saves your settings to a preset file automatically.

---

## Game notes (under testing)

### Resident Evil 2 (2019)

- Install ReShade for `re2.exe` with **DirectX 10/11/12**.
- Turn **HDR off** in the game's display settings.
- If ReShade doesn't load with the current DirectX 12 version, use the original DirectX 11 release from Steam: **Properties → Betas** lists the non-ray-traced branch.
- Good test spots: the police station hall and close-ups of Leon or Claire.

### Resident Evil 0 HD Remaster

- The game runs on **DirectX 9**, so choose **Direct3D 9** in the ReShade installer.
- Backgrounds are pre-rendered, so contact shadows and the skin pass mostly affect characters, and the detail boost can sharpen compression artifacts in backgrounds. Start with the **Light** preset.

Results, screenshots and recommended settings for both games will be added here once testing is done.

## Settings reference

| Setting | What it does |
|---|---|
| Look preset | Light, Balanced or Strong. Custom uses the sliders below it |
| Overall strength | Scales every effect |
| Lighting contrast | Deeper light/shadow shaping on faces, cloth and walls |
| Material detail | Fine surface texture, adaptive so noise and flat areas stay calm |
| Textured highlights | Breaks up smooth, plastic-looking highlights |
| Filmic contrast | Gentle S-curve |
| Vibrance | Lifts muted colours; skin is protected |
| Contact shadow strength | How dark contact shadows get |
| Skin light wrap | Warm light bleeding into the shadow side of skin |
| Skin detail | Variation and texture on skin |
| Contact shadow radius / distance | Size of contact shadows and how far into the scene they appear |
| Game vertical field of view | Match the game for correct shadow shapes |
| Skin detection width | Narrow it if non-skin surfaces are picked up |
| Split-screen compare, Debug view | Comparison and diagnostics |

| Preprocessor switch | Default | Use |
|---|---|---|
| `NL_CONTACT_SHADOWS` | 1 | 0 skips all depth work |
| `NL_SKIN` | 1 | 0 skips the skin pass |
| `NL_AO_SAMPLES` | 8 | 4 is faster, 12 is smoother |

## Troubleshooting

- **Error about `ReShade.fxh` when the effect loads**: reinstall ReShade with the standard effects package ticked.
- **No contact shadows**: depth isn't available or is set up wrong. See step 3.
- **Dark halos around objects**: lower Contact shadow radius, or check depth with DisplayDepth.
- **Image looks grainy**: lower Material detail and Skin detail, or turn off the game's film grain.
- **Colours look washed out or wrong**: turn HDR off in the game.

---

## Roadmap

**v0.2: real-game tuning**
- Finish testing in RE2 and RE0 HD Remaster on a GTX 1650
- Measured performance numbers and recommended settings per game
- Ready-made ReShade preset files for both games
- Before/after game screenshots in this README

**v0.3: quality**
- Depth-aware lighting contrast to remove the remaining edge halos
- Better skin detection that uses depth as well as colour, to cut false positives on brick and wood
- Backlit edges on hair and foliage (light passing through thin surfaces)
- Steadier contact shadows in motion

**Later**
- HDR (scRGB and HDR10) support
- A simple installer script
- More tested games, based on requests

## Testing and feedback

Every push compiles the shader with ReShade's own compiler for DirectX 9, DirectX 10–12, OpenGL and Vulkan, at several resolutions and with each switch on and off. It also renders a test scene through every pass and checks the result. You can run the same checks on Linux:

```
bash tools/build_fxc.sh build
bash tools/check_shader.sh build
python3 tests/render_test.py build     # needs moderngl, numpy, pillow and Mesa
```

The most useful feedback right now is from real games. When opening an issue, please include:

- the game, your GPU and resolution
- screenshots with NeuralLook off and on, plus the Contact shadows and Skin mask debug views
- the time NeuralLook takes in ReShade's Statistics tab

## License

MIT. See [LICENSE](LICENSE).

NeuralLook is an independent project. It is not affiliated with or endorsed by NVIDIA, Capcom or the ReShade project. DLSS is a trademark of NVIDIA Corporation, and Resident Evil is a trademark of Capcom.
