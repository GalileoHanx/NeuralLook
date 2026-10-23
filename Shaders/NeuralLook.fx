/*
    NeuralLook.fx  v0.2.0
    https://github.com/GalileoHanx/NeuralLook  -  MIT License

    A neural-rendering-inspired look for GPUs without tensor cores.
    Built and tuned for GTX 1650-class cards. ReShade 5.0 or newer.
    Not affiliated with or endorsed by NVIDIA.

    This is NOT neural rendering. No AI model runs here. It imitates the parts of
    the DLSS 5 look that ordinary shader math can fake:

      Core look        local lighting contrast, material micro-detail, highlights that
                       pick up surface texture, gentle filmic tone, vibrance
      Shadows          contact shadows from depth, or depth-free shadows worked out from
                       the image when the game gives ReShade no depth (chosen automatically)
      Skin             warm, subsurface-style light wrap and extra texture on skin tones
      Mood             colour grades: cinematic warm, survival horror, teal and orange,
                       golden hour, cold night
      Lens             soft light glow, vignette, film grain
      Tools            presets, on-screen status, split-screen compare, debug views

    Cost: blurs run at half and quarter resolution, shadows at half resolution.
    Built for SDR.

    Preprocessor switches (in ReShade, at the bottom of this effect's settings):
      NL_CONTACT_SHADOWS  1 = on, 0 = removes every depth pass (depth-free shadows still work)
      NL_SKIN             1 = on, 0 = removes the skin pass
*/

#include "ReShade.fxh"
#include "DrawText.fxh"

#ifndef NL_CONTACT_SHADOWS
    #define NL_CONTACT_SHADOWS 1
#endif
#ifndef NL_SKIN
    #define NL_SKIN 1
#endif

#ifdef BUFFER_COLOR_SPACE
    #if BUFFER_COLOR_SPACE > 1
        #warning "NeuralLook is tuned for SDR. Turn HDR off in the game for correct colours."
    #endif
#endif

// ---------------------------------------------------------------------------
// UI: main settings
// ---------------------------------------------------------------------------

uniform int NL_Preset <
    ui_type = "combo";
    ui_items = "Custom (use the Custom sliders)\0Light\0Balanced\0Strong\0Classic games (pre-rendered backgrounds)\0";
    ui_label = "Look preset";
    ui_tooltip = "How strongly the image is reworked.\nClassic games is tuned for fixed-camera games with pre-rendered backgrounds,\nsuch as Resident Evil 0 and the Resident Evil HD Remaster.\nChoose Custom to tune each effect by hand.";
> = 2;

uniform float NL_Master <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Overall strength";
    ui_tooltip = "Scales everything NeuralLook does. 0 turns it off.";
> = 1.0;

uniform int NL_Mood <
    ui_type = "combo";
    ui_items = "Neutral (no grade)\0Cinematic warm\0Survival horror\0Teal and orange\0Golden hour\0Cold night\0";
    ui_label = "Mood";
    ui_tooltip = "A colour grade on top of the look.\nSurvival horror: cooler, greener shadows, less saturation, deeper blacks.";
> = 0;

uniform float NL_MoodStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Mood strength";
> = 0.6;

uniform int NL_ShadowSource <
    ui_type = "combo";
    ui_items = "Auto (depth when available)\0Contact shadows only (needs depth)\0Depth-free shadows only\0Off\0";
    ui_label = "Shadows";
    ui_tooltip = "Auto uses contact shadows from the depth buffer when the game provides one,\nand switches to depth-free shadows (worked out from the image) when it doesn't.";
> = 0;

uniform int NL_ShadowQuality <
    ui_type = "combo";
    ui_items = "Fast\0Normal\0High\0";
    ui_label = "Contact shadow quality";
    ui_tooltip = "Fast is lightest on older GPUs. Only affects contact shadows from depth.";
> = 1;

uniform bool NL_ShowStatus <
    ui_label = "Show status";
    ui_tooltip = "Shows whether depth was found and which shadows are in use,\nonly while the ReShade menu is open.";
> = true;

// ---------------------------------------------------------------------------
// UI: lens and atmosphere
// ---------------------------------------------------------------------------

uniform float NL_Glow <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Lens and atmosphere";
    ui_label = "Light glow";
    ui_tooltip = "Soft glow around lamps, windows and other bright areas.";
> = 0.20;

uniform float NL_GlowThreshold <
    ui_type = "slider"; ui_min = 0.4; ui_max = 0.95; ui_step = 0.01;
    ui_category = "Lens and atmosphere";
    ui_label = "Glow threshold";
    ui_tooltip = "Lower it to let more of the image glow.";
> = 0.70;

uniform float NL_Vignette <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Lens and atmosphere";
    ui_label = "Vignette";
    ui_tooltip = "Darkens the corners like a camera lens.";
> = 0.0;

uniform float NL_Grain <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Lens and atmosphere";
    ui_label = "Film grain";
    ui_tooltip = "Fine, moving grain, strongest in the mid-tones.";
> = 0.0;

// ---------------------------------------------------------------------------
// UI: custom sliders (used when Look preset is Custom)
// ---------------------------------------------------------------------------

uniform float NL_Clarity <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: core look"; ui_category_closed = true;
    ui_label = "Lighting contrast";
    ui_tooltip = "Deepens the light/shadow shaping across faces, cloth and walls.";
> = 0.45;

uniform float NL_Detail <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: core look"; ui_category_closed = true;
    ui_label = "Material detail";
    ui_tooltip = "Brings out fine surface texture. Adaptive, so flat areas and noise are left alone.";
> = 0.40;

uniform float NL_Highlight <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: core look"; ui_category_closed = true;
    ui_label = "Textured highlights";
    ui_tooltip = "Breaks up smooth, plastic-looking highlights using the surface texture underneath.";
> = 0.35;

uniform float NL_Tone <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: core look"; ui_category_closed = true;
    ui_label = "Filmic contrast";
    ui_tooltip = "A gentle S-curve: slightly deeper shadows, slightly brighter highlights.";
> = 0.25;

uniform float NL_Vibrance <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
    ui_category = "Custom: core look"; ui_category_closed = true;
    ui_label = "Vibrance";
    ui_tooltip = "Lifts muted colours more than saturated ones. Skin is protected.";
> = 0.10;

uniform float NL_AOStrength <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: shadows and skin"; ui_category_closed = true;
    ui_label = "Contact shadow strength";
> = 0.55;

uniform float NL_ImageShadow <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: shadows and skin"; ui_category_closed = true;
    ui_label = "Depth-free shadow strength";
    ui_tooltip = "Deepens creases, corners and areas under objects using the image itself.";
> = 0.40;

uniform float NL_SSS <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: shadows and skin"; ui_category_closed = true;
    ui_label = "Skin light wrap";
    ui_tooltip = "Warm light bleeding into the shadow side of skin, like subsurface scattering.";
> = 0.40;

uniform float NL_SkinDetail <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: shadows and skin"; ui_category_closed = true;
    ui_label = "Skin detail";
    ui_tooltip = "Adds variation and pore-level texture to skin so it looks less waxy.";
> = 0.35;

// ---------------------------------------------------------------------------
// UI: scene settings (used by every preset)
// ---------------------------------------------------------------------------

uniform float NL_AORadius <
    ui_type = "slider"; ui_min = 0.05; ui_max = 3.0; ui_step = 0.01;
    ui_category = "Scene settings"; ui_category_closed = true;
    ui_label = "Contact shadow radius";
    ui_tooltip = "Size of the shadowed area around creases and contact points.\nGame units differ, so raise it if shadows are too thin, lower it if they look like dark halos.";
> = 0.5;

uniform float NL_AOFade <
    ui_type = "slider"; ui_min = 0.02; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Scene settings"; ui_category_closed = true;
    ui_label = "Contact shadow distance";
    ui_tooltip = "How far into the scene contact shadows are drawn (fraction of depth range).";
> = 0.3;

uniform float NL_FovDeg <
    ui_type = "slider"; ui_min = 50.0; ui_max = 110.0; ui_step = 1.0;
    ui_category = "Scene settings"; ui_category_closed = true;
    ui_label = "Game vertical field of view";
    ui_tooltip = "Roughly match the game's FOV so contact shadow shapes come out right.";
> = 70.0;

uniform float NL_SkinRange <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_category = "Scene settings"; ui_category_closed = true;
    ui_label = "Skin detection width";
    ui_tooltip = "Lower it if wood, sand or brick get treated as skin (check with the Skin mask debug view).";
> = 1.0;

// ---------------------------------------------------------------------------
// UI: compare and debug
// ---------------------------------------------------------------------------

uniform bool NL_Compare <
    ui_category = "Compare and debug";
    ui_label = "Split-screen compare";
    ui_tooltip = "Left of the line: NeuralLook. Right of the line: original game.";
> = false;

uniform float NL_SplitPos <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Compare and debug";
    ui_label = "Split position";
> = 0.5;

uniform int NL_Debug <
    ui_type = "combo";
    ui_items = "Off\0Shadows\0Skin mask\0Lighting contrast\0";
    ui_category = "Compare and debug";
    ui_label = "Debug view";
> = 0;

// Filled in by ReShade
uniform bool NL_OverlayOpen < source = "overlay_open"; >;
uniform int NL_Frame < source = "framecount"; >;

// ---------------------------------------------------------------------------
// Textures
// ---------------------------------------------------------------------------

#define NL_HALF_W  (BUFFER_WIDTH / 2)
#define NL_HALF_H  (BUFFER_HEIGHT / 2)
#define NL_QUART_W (BUFFER_WIDTH / 4)
#define NL_QUART_H (BUFFER_HEIGHT / 4)

texture NL_HalfTex   { Width = NL_HALF_W;  Height = NL_HALF_H;  Format = RGBA16F; }; // colour + linear depth
texture NL_BlurATex  { Width = NL_HALF_W;  Height = NL_HALF_H;  Format = RGBA16F; };
texture NL_SmallTex  { Width = NL_HALF_W;  Height = NL_HALF_H;  Format = RGBA16F; }; // small blur
texture NL_QuartTex  { Width = NL_QUART_W; Height = NL_QUART_H; Format = RGBA16F; };
texture NL_QBlurATex { Width = NL_QUART_W; Height = NL_QUART_H; Format = RGBA16F; };
texture NL_LargeTex  { Width = NL_QUART_W; Height = NL_QUART_H; Format = RGBA16F; }; // large blur

sampler NL_Half   { Texture = NL_HalfTex; };
sampler NL_BlurA  { Texture = NL_BlurATex; };
sampler NL_Small  { Texture = NL_SmallTex; };
sampler NL_Quart  { Texture = NL_QuartTex; };
sampler NL_QBlurA { Texture = NL_QBlurATex; };
sampler NL_Large  { Texture = NL_LargeTex; };

#if NL_CONTACT_SHADOWS
texture NL_AOTex        { Width = NL_HALF_W; Height = NL_HALF_H; Format = R16F; };
texture NL_AOBlurTex    { Width = NL_HALF_W; Height = NL_HALF_H; Format = R16F; };
texture NL_StateTex     { Width = 1; Height = 1; Format = R16F; };  // smoothed "depth is usable" flag
texture NL_StatePrevTex { Width = 1; Height = 1; Format = R16F; };
sampler NL_AO        { Texture = NL_AOTex; };
sampler NL_AOBlur    { Texture = NL_AOBlurTex; };
sampler NL_State     { Texture = NL_StateTex;     MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
sampler NL_StatePrev { Texture = NL_StatePrevTex; MagFilter = POINT; MinFilter = POINT; MipFilter = POINT; };
#endif

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct NLParams
{
    float clarity;
    float detail;
    float highlight;
    float tone;
    float vibrance;
    float ao;
    float imageShadow;
    float sss;
    float skinDetail;
};

NLParams NL_GetParams()
{
    NLParams p;
    if (NL_Preset == 1)      // Light
    {
        p.clarity = 0.25; p.detail = 0.25; p.highlight = 0.20; p.tone = 0.15; p.vibrance = 0.05;
        p.ao = 0.35; p.imageShadow = 0.25; p.sss = 0.25; p.skinDetail = 0.20;
    }
    else if (NL_Preset == 2) // Balanced
    {
        p.clarity = 0.45; p.detail = 0.40; p.highlight = 0.35; p.tone = 0.25; p.vibrance = 0.10;
        p.ao = 0.55; p.imageShadow = 0.40; p.sss = 0.40; p.skinDetail = 0.35;
    }
    else if (NL_Preset == 3) // Strong
    {
        p.clarity = 0.70; p.detail = 0.60; p.highlight = 0.50; p.tone = 0.40; p.vibrance = 0.15;
        p.ao = 0.80; p.imageShadow = 0.60; p.sss = 0.55; p.skinDetail = 0.50;
    }
    else if (NL_Preset == 4) // Classic games: less fine detail (protects compressed backgrounds),
    {                        // more shaping, shadows and skin
        p.clarity = 0.40; p.detail = 0.15; p.highlight = 0.25; p.tone = 0.30; p.vibrance = 0.08;
        p.ao = 0.50; p.imageShadow = 0.55; p.sss = 0.45; p.skinDetail = 0.25;
    }
    else                     // Custom
    {
        p.clarity = NL_Clarity; p.detail = NL_Detail; p.highlight = NL_Highlight; p.tone = NL_Tone;
        p.vibrance = NL_Vibrance; p.ao = NL_AOStrength; p.imageShadow = NL_ImageShadow;
        p.sss = NL_SSS; p.skinDetail = NL_SkinDetail;
    }

    p.clarity *= NL_Master; p.detail *= NL_Master; p.highlight *= NL_Master; p.tone *= NL_Master;
    p.vibrance *= NL_Master; p.ao *= NL_Master; p.imageShadow *= NL_Master;
    p.sss *= NL_Master; p.skinDetail *= NL_Master;
    return p;
}

float NL_Luma(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Interleaved gradient noise: stable per-pixel pattern, used for dithering and sample rotation
float NL_IGN(float2 p)
{
    return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715))));
}

// Unstructured hash for film grain
float NL_Hash(float2 p)
{
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

// Change luminance by delta while keeping the pixel's hue.
// Brightening eases off towards white so highlights don't clip.
float3 NL_ApplyLuma(float3 c, float delta)
{
    float l = NL_Luma(c);
    if (delta > 0.0)
    {
        float room = saturate(1.0 - l);
        delta = delta * room / (room + delta + 1e-5);
    }
    float3 chroma = clamp(c / max(l, 0.001), 0.0, 4.0);
    float3 scale = lerp(float3(1.0, 1.0, 1.0), chroma, saturate(l * 8.0));
    return c + delta * scale;
}

// Soft skin-tone mask on normalised rgb (chromaticity), so it holds on both the
// lit and the shadowed side of a face, and on light and dark skin.
float NL_SkinMask(float3 rgb)
{
    float sum = rgb.r + rgb.g + rgb.b;
    float2 rg = rgb.rg / max(sum, 0.001);
    float2 d = (rg - float2(0.42, 0.315)) / (float2(0.07, 0.035) * NL_SkinRange);
    float m = 1.0 - smoothstep(0.6, 1.0, length(d));
    float y = dot(rgb, float3(0.299, 0.587, 0.114));
    m *= smoothstep(0.04, 0.10, y) * (1.0 - smoothstep(0.90, 0.99, y));
    m *= smoothstep(0.02, 0.06, rgb.r - rgb.b);
    return m;
}

// Colour grades. Each one: white balance, lift (shadow colour), gain (highlight colour),
// contrast and saturation. Skin keeps some of its original hue.
float3 NL_ApplyMood(float3 c, float strength, float skin)
{
    if (NL_Mood == 0 || strength <= 0.0)
        return c;

    float temp, tint, sat, con;
    float3 lift, gain;
    if (NL_Mood == 1)      // Cinematic warm
    {
        temp = 0.25; tint = 0.0; sat = 1.06; con = 1.08;
        lift = float3(0.010, 0.005, 0.0); gain = float3(1.03, 1.0, 0.96);
    }
    else if (NL_Mood == 2) // Survival horror
    {
        temp = -0.25; tint = -0.20; sat = 0.78; con = 1.12;
        lift = float3(0.0, 0.010, 0.014); gain = float3(0.97, 1.0, 0.99);
    }
    else if (NL_Mood == 3) // Teal and orange
    {
        temp = 0.0; tint = 0.0; sat = 1.10; con = 1.06;
        lift = float3(0.0, 0.018, 0.030); gain = float3(1.04, 1.0, 0.94);
    }
    else if (NL_Mood == 4) // Golden hour
    {
        temp = 0.45; tint = 0.05; sat = 1.10; con = 1.02;
        lift = float3(0.015, 0.008, 0.0); gain = float3(1.05, 1.01, 0.92);
    }
    else                   // Cold night
    {
        temp = -0.50; tint = 0.0; sat = 0.85; con = 1.08;
        lift = float3(0.0, 0.006, 0.022); gain = float3(0.94, 0.98, 1.05);
    }

    float l0 = NL_Luma(c);
    float3 g = c * float3(1.0 + temp * 0.12, 1.0 - tint * 0.06, 1.0 - temp * 0.12);
    g *= l0 / max(NL_Luma(g), 1e-4);                        // white balance keeps brightness
    g = g * gain + lift * (1.0 - g);                         // tint shadows and highlights
    float l1 = NL_Luma(g);
    g = NL_ApplyLuma(g, (0.45 + (l1 - 0.45) * con) - l1);    // contrast around mid-grey
    float l2 = NL_Luma(g);
    g = lerp(float3(l2, l2, l2), g, sat);                    // saturation
    g = lerp(g, c * (NL_Luma(g) / max(l0, 1e-4)), skin * 0.35);
    return lerp(c, saturate(g), strength);
}

// 9-tap Gaussian using 5 bilinear fetches. Alpha (depth) is passed through.
float4 NL_Blur(sampler s, float2 uv, float2 dir)
{
    float4 c = tex2Dlod(s, float4(uv, 0.0, 0.0));
    float2 o1 = dir * 1.3846153846;
    float2 o2 = dir * 3.2307692308;
    float3 sum = c.rgb * 0.2270270270;
    sum += (tex2Dlod(s, float4(uv + o1, 0.0, 0.0)).rgb + tex2Dlod(s, float4(uv - o1, 0.0, 0.0)).rgb) * 0.3162162162;
    sum += (tex2Dlod(s, float4(uv + o2, 0.0, 0.0)).rgb + tex2Dlod(s, float4(uv - o2, 0.0, 0.0)).rgb) * 0.0702702703;
    return float4(sum, c.a);
}

// ---------------------------------------------------------------------------
// Passes: downsample and blur pyramid
// ---------------------------------------------------------------------------

float4 PS_NL_Down(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // Sampling at half-res texel centres with bilinear filtering averages a 2x2 block
    float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
    float z = ReShade::GetLinearizedDepth(uv);
    return float4(c, z);
}

float4 PS_NL_SmallH(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_Blur(NL_Half, uv, float2(1.0 / NL_HALF_W, 0.0));
}

float4 PS_NL_SmallV(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_Blur(NL_BlurA, uv, float2(0.0, 1.0 / NL_HALF_H));
}

float4 PS_NL_DownQ(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(NL_Small, uv);
}

float4 PS_NL_LargeH(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_Blur(NL_Quart, uv, float2(1.5 / NL_QUART_W, 0.0));
}

float4 PS_NL_LargeV(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_Blur(NL_QBlurA, uv, float2(0.0, 1.5 / NL_QUART_H));
}

// ---------------------------------------------------------------------------
// Passes: depth check and contact shadows
// ---------------------------------------------------------------------------

#if NL_CONTACT_SHADOWS

// Samples an 8x8 grid of the depth buffer. Depth counts as usable when enough of the
// screen has real (not cleared) depth with some variation. Smoothed over ~half a second
// so loading screens and menus don't make it flicker.
float4 PS_NL_DepthCheck(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float count = 0.0;
    float zmin = 1.0;
    float zmax = 0.0;

    [unroll]
    for (int y = 0; y < 8; y++)
    {
        [unroll]
        for (int x = 0; x < 8; x++)
        {
            float z = ReShade::GetLinearizedDepth((float2(x, y) + 0.5) / 8.0);
            if (z > 0.00005 && z < 0.999)
            {
                count += 1.0;
                zmin = min(zmin, z);
                zmax = max(zmax, z);
            }
        }
    }

    float valid = (count >= 6.0 && (zmax - zmin) > 0.0002) ? 1.0 : 0.0;
    float prev = tex2Dlod(NL_StatePrev, float4(0.5, 0.5, 0.0, 0.0)).r;
    return float4(lerp(prev, valid, 0.08), 0.0, 0.0, 0.0);
}

float4 PS_NL_StateCopy(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dlod(NL_State, float4(0.5, 0.5, 0.0, 0.0));
}

float3 NL_ViewPos(float2 uv, float tanHalf)
{
    float z = ReShade::GetLinearizedDepth(uv) * RESHADE_DEPTH_LINEARIZATION_FAR_PLANE;
    float2 ndc = uv * 2.0 - 1.0;
    return float3(ndc * float2(BUFFER_ASPECT_RATIO, 1.0) * tanHalf * z, z);
}

float4 PS_NL_AO(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // Skip the work when contact shadows aren't going to be used
    if (NL_ShadowSource >= 2)
        return float4(0.0, 0.0, 0.0, 0.0);
    if (NL_ShadowSource == 0 && tex2Dlod(NL_State, float4(0.5, 0.5, 0.0, 0.0)).r < 0.05)
        return float4(0.0, 0.0, 0.0, 0.0);

    float zN = ReShade::GetLinearizedDepth(uv);
    // No depth, first-person weapon too close, or sky: no shadow
    if (zN < 0.0001 || zN > 0.98)
        return float4(0.0, 0.0, 0.0, 0.0);

    float tanHalf = tan(radians(NL_FovDeg) * 0.5);
    float2 px = BUFFER_PIXEL_SIZE * 2.0;

    float3 p  = NL_ViewPos(uv, tanHalf);
    float3 pr = NL_ViewPos(uv + float2(px.x, 0.0), tanHalf);
    float3 pl = NL_ViewPos(uv - float2(px.x, 0.0), tanHalf);
    float3 pd = NL_ViewPos(uv + float2(0.0, px.y), tanHalf);
    float3 pu = NL_ViewPos(uv - float2(0.0, px.y), tanHalf);

    // Pick the smaller depth step on each axis so normals stay clean at object edges
    float3 dx = abs(pr.z - p.z) < abs(p.z - pl.z) ? pr - p : p - pl;
    float3 dy = abs(pd.z - p.z) < abs(p.z - pu.z) ? pd - p : p - pu;
    float3 n = cross(dy, dx);
    float nl = dot(n, n);
    if (nl < 1e-20)
        return float4(0.0, 0.0, 0.0, 0.0);
    n *= rsqrt(nl);
    if (n.z > 0.0)
        n = -n;

    float projScale = (BUFFER_HEIGHT * 0.5) / tanHalf;
    float radiusPx = clamp(NL_AORadius * projScale / p.z, 2.0, 48.0);
    float R = radiusPx * p.z / projScale;
    float R2 = R * R;

    int samples = 4 + 4 * clamp(NL_ShadowQuality, 0, 2);
    float rcpSamples = 1.0 / samples;
    float noise = NL_IGN(vpos.xy);
    float occ = 0.0;

    [loop]
    for (int i = 0; i < 12; i++)
    {
        if (i >= samples)
            break;
        float t = (i + 0.5) * rcpSamples;
        float a = (i + noise) * 2.39996323;            // golden-angle spiral
        float r = sqrt(t) * radiusPx;
        float2 suv = uv + float2(cos(a), sin(a)) * r * BUFFER_PIXEL_SIZE;
        float3 v = NL_ViewPos(suv, tanHalf) - p;
        float d2 = dot(v, v);
        occ += saturate(dot(n, v) * rsqrt(d2 + 1e-6) - 0.15) * saturate(1.0 - d2 / R2);
    }

    occ = saturate(occ * rcpSamples * 4.0);
    occ *= 1.0 - smoothstep(NL_AOFade * 0.5, NL_AOFade, zN);
    // Fade out at the screen border, where samples fall off-screen
    float2 border = smoothstep(0.0, 0.03, min(uv, 1.0 - uv));
    occ *= border.x * border.y;
    return float4(occ, 0.0, 0.0, 0.0);
}

// 5-tap depth-aware blur so shadows don't bleed across object edges
float4 NL_AOBlurDir(sampler s, float2 uv, float2 dir)
{
    float zc = tex2Dlod(NL_Half, float4(uv, 0.0, 0.0)).a;
    float sum = 0.0;
    float wsum = 0.0;

    [unroll]
    for (int i = -2; i <= 2; i++)
    {
        float2 suv = uv + dir * i;
        float zs = tex2Dlod(NL_Half, float4(suv, 0.0, 0.0)).a;
        float w = (3.0 - abs(i)) * (saturate(1.0 - abs(zs - zc) / (zc * 0.05 + 1e-5)) + 0.001);
        sum += tex2Dlod(s, float4(suv, 0.0, 0.0)).r * w;
        wsum += w;
    }
    return float4(sum / max(wsum, 1e-5), 0.0, 0.0, 0.0);
}

float4 PS_NL_AOBlurH(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_AOBlurDir(NL_AO, uv, float2(1.0 / NL_HALF_W, 0.0));
}

float4 PS_NL_AOBlurV(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return NL_AOBlurDir(NL_AOBlur, uv, float2(0.0, 1.0 / NL_HALF_H));
}

// Depth-aware upsample from half to full resolution
float NL_AOUpsample(float2 uv, float zFull)
{
    float2 hs = float2(NL_HALF_W, NL_HALF_H);
    float2 tc = uv * hs - 0.5;
    float2 b = floor(tc);
    float2 f = tc - b;
    float sum = 0.0;
    float wsum = 0.0;

    [unroll]
    for (int j = 0; j < 4; j++)
    {
        float2 o = float2(j % 2, j / 2);
        float2 suv = (b + o + 0.5) / hs;
        float2 bw = lerp(1.0 - f, f, o);
        float zs = tex2Dlod(NL_Half, float4(suv, 0.0, 0.0)).a;
        float w = bw.x * bw.y * (saturate(1.0 - abs(zs - zFull) / (zFull * 0.05 + 1e-5)) + 0.001);
        sum += tex2Dlod(NL_AO, float4(suv, 0.0, 0.0)).r * w;
        wsum += w;
    }
    return sum / max(wsum, 1e-6);
}

#endif

// ---------------------------------------------------------------------------
// Status badge (only while the ReShade menu is open)
// ---------------------------------------------------------------------------

float3 NL_DrawStatus(float2 tc, float3 c, float depthState)
{
    float2 p = tc * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float2 boxMin = float2(12.0, 12.0);
    float2 boxMax = float2(12.0 + 16.0 + 42.0 * 9.0, 12.0 + 12.0 + 3.0 * 22.0);
    if (p.x < boxMin.x || p.y < boxMin.y || p.x > boxMax.x || p.y > boxMax.y)
        return c;

    c = lerp(c, float3(0.06, 0.06, 0.07), 0.82);

    float title = 0.0;
    float state = 0.0;
    float hint = 0.0;
    float2 org = boxMin + 8.0;

    int line0[16] = { __N, __e, __u, __r, __a, __l, __L, __o, __o, __k, __Space, __0, __Dot, __2, __Dot, __0 };
    DrawText_String(org, 18, 1, tc, line0, 16, title);

    bool good = true;
    float2 org1 = org + float2(0.0, 22.0);
    if (NL_ShadowSource == 3)
    {
        int s3[12] = { __S, __h, __a, __d, __o, __w, __s, __Colon, __Space, __o, __f, __f };
        DrawText_String(org1, 18, 1, tc, s3, 12, state);
    }
    else if (NL_ShadowSource == 2 || NL_CONTACT_SHADOWS == 0)
    {
        int s2[24] = { __S, __h, __a, __d, __o, __w, __s, __Colon, __Space, __d, __e, __p, __t, __h, __Minus, __f, __r, __e, __e, __Space, __m, __o, __d, __e };
        DrawText_String(org1, 18, 1, tc, s2, 24, state);
    }
    else if (depthState >= 0.5)
    {
        int s0[31] = { __D, __e, __p, __t, __h, __Space, __f, __o, __u, __n, __d, __Colon, __Space, __c, __o, __n, __t, __a, __c, __t, __Space, __s, __h, __a, __d, __o, __w, __s, __Space, __o, __n };
        DrawText_String(org1, 18, 1, tc, s0, 31, state);
    }
    else if (NL_ShadowSource == 1)
    {
        good = false;
        int s4[42] = { __N, __o, __Space, __d, __e, __p, __t, __h, __Space, __f, __o, __u, __n, __d, __Colon, __Space, __c, __o, __n, __t, __a, __c, __t, __Space, __s, __h, __a, __d, __o, __w, __s, __Space, __n, __e, __e, __d, __Space, __d, __e, __p, __t, __h };
        DrawText_String(org1, 18, 1, tc, s4, 42, state);
    }
    else
    {
        good = false;
        int s1[40] = { __N, __o, __Space, __d, __e, __p, __t, __h, __Space, __f, __o, __u, __n, __d, __Colon, __Space, __u, __s, __i, __n, __g, __Space, __d, __e, __p, __t, __h, __Minus, __f, __r, __e, __e, __Space, __s, __h, __a, __d, __o, __w, __s };
        DrawText_String(org1, 18, 1, tc, s1, 40, state);
    }

    // DrawText_String doesn't bracket its position argument, so pass a plain variable
    float2 org2 = org + float2(0.0, 44.0);
    int line2[31] = { __U, __n, __t, __i, __c, __k, __Space, __S, __h, __o, __w, __Space, __s, __t, __a, __t, __u, __s, __Space, __t, __o, __Space, __h, __i, __d, __e, __Space, __t, __h, __i, __s };
    DrawText_String(org2, 18, 1, tc, line2, 31, hint);

    float3 stateCol = good ? float3(0.45, 0.95, 0.55) : float3(1.0, 0.75, 0.30);
    c = lerp(c, float3(0.95, 0.95, 0.95), saturate(title));
    c = lerp(c, stateCol, saturate(state));
    c = lerp(c, float3(0.62, 0.62, 0.65), saturate(hint));
    return c;
}

// ---------------------------------------------------------------------------
// Final composite
// ---------------------------------------------------------------------------

float4 PS_NL_Composite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;

    float depthState = 0.0;
#if NL_CONTACT_SHADOWS
    depthState = tex2Dlod(NL_State, float4(0.5, 0.5, 0.0, 0.0)).r;
#endif

    // Split-screen compare (right side shows the untouched game)
    if (NL_Compare && uv.x > NL_SplitPos)
    {
        float3 o = orig;
        if (uv.x - NL_SplitPos < BUFFER_RCP_WIDTH * 1.5)
            o = float3(1.0, 1.0, 1.0);
        if (NL_ShowStatus && NL_OverlayOpen)
            o = NL_DrawStatus(uv, o, depthState);
        return float4(o, 1.0);
    }

    NLParams P = NL_GetParams();

    float3 small = tex2D(NL_Small, uv).rgb;
    float3 large = tex2D(NL_Large, uv).rgb;
    float lumaO = NL_Luma(orig);
    float lumaS = NL_Luma(small);
    float lumaL = NL_Luma(large);

    float3 c = orig;

    // Skin light wrap. Light from the lit side bleeds into the shadow side,
    // red farthest, blue least, like light scattering under skin.
    float skin = 0.0;
#if NL_SKIN
    skin = NL_SkinMask(small);
    float3 wrap = max(small - c, 0.0) * float3(1.0, 0.45, 0.25);
    c += wrap * P.sss * 1.5 * skin;
    // Shadowed skin turns slightly redder and richer, as scattered light does
    float shadowSide = 1.0 - smoothstep(0.15, 0.55, lumaO);
    c *= lerp(float3(1.0, 1.0, 1.0), float3(1.07, 0.98, 0.93), skin * shadowSide * saturate(P.sss * 1.5));
#endif

    // Adaptive micro-detail (contrast-adaptive, so noise and flat areas stay calm)
    float2 px = BUFFER_PIXEL_SIZE;
    float lN = NL_Luma(tex2D(ReShade::BackBuffer, uv - float2(0.0, px.y)).rgb);
    float lS = NL_Luma(tex2D(ReShade::BackBuffer, uv + float2(0.0, px.y)).rgb);
    float lE = NL_Luma(tex2D(ReShade::BackBuffer, uv + float2(px.x, 0.0)).rgb);
    float lW = NL_Luma(tex2D(ReShade::BackBuffer, uv - float2(px.x, 0.0)).rgb);
    float mn = min(lumaO, min(min(lN, lS), min(lE, lW)));
    float mx = max(lumaO, max(max(lN, lS), max(lE, lW)));
    float amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 0.0001)));
    float hf = lumaO - (lN + lS + lE + lW) * 0.25;
    float detail = hf * amp * P.detail * (2.0 + P.skinDetail * skin * 0.75);

    // Textured highlights and skin variation (mid-frequency detail)
    float midF = lumaO - lumaS;
    float highlight = midF * smoothstep(0.55, 0.95, lumaO) * P.highlight * 1.5;
    float skinVar = midF * skin * P.skinDetail * 1.5;

    // Local lighting contrast. Soft-limited, and eased off next to strong edges
    // (where the small and large blurs disagree) so objects don't get dark outlines.
    float ld = lumaO - lumaL;
    ld = ld / (1.0 + abs(ld) * 4.0);
    float midMask = smoothstep(0.0, 0.2, lumaO) * (1.0 - smoothstep(0.8, 1.0, lumaO));
    float edge = saturate(abs(lumaS - lumaL) * 6.0);
    float contrast = ld * midMask * (1.0 - 0.75 * edge) * P.clarity * 1.5;

    c = NL_ApplyLuma(c, detail + highlight + skinVar + contrast);

    // Shadows: contact shadows from depth, depth-free shadows from the image, or both off
    float occDepth = 0.0;
    float wDepth = 0.0;
#if NL_CONTACT_SHADOWS
    if (NL_ShadowSource <= 1)
        occDepth = NL_AOUpsample(uv, ReShade::GetLinearizedDepth(uv));
    if (NL_ShadowSource == 0)
        wDepth = smoothstep(0.3, 0.7, depthState);
    else if (NL_ShadowSource == 1)
        wDepth = 1.0;
#endif
    float wImage = (NL_ShadowSource == 3 || NL_ShadowSource == 1) ? 0.0 : 1.0 - wDepth;

    // Depth-free shadows: areas darker than their surroundings at small and medium
    // scale are treated as creases, corners and the ground under objects.
    // Strong light/dark edges (an object against a bright background) are left alone,
    // so objects don't get dark outlines.
    float cavity = saturate((lumaS - lumaO) * 6.0) * (1.0 - smoothstep(0.06, 0.16, lumaS - lumaO));
    float hollow = saturate((lumaL - lumaS) * 3.0) * (1.0 - saturate(abs(lumaO - lumaS) * 6.0));
    float occImage = saturate(cavity * 0.5 + hollow * 0.8) * smoothstep(0.03, 0.2, lumaO);

    float occ = saturate(occDepth * wDepth * P.ao + occImage * wImage * P.imageShadow);
    float shade = occ * (1.0 - 0.6 * smoothstep(0.6, 1.0, lumaO));
    float3 tint = lerp(float3(1.0, 1.0, 1.0), float3(0.65, 1.0, 1.08), skin * saturate(P.sss * 2.0));
    c *= 1.0 - shade * tint;

    // Gentle filmic S-curve
    float l2 = saturate(NL_Luma(c));
    float curved = l2 * l2 * (3.0 - 2.0 * l2);
    c = NL_ApplyLuma(c, (curved - l2) * P.tone);

    // Vibrance (protects skin and already-saturated colours)
    float l3 = NL_Luma(c);
    float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float vib = P.vibrance * (1.0 - saturate(sat)) * (1.0 - skin * 0.8);
    c = lerp(float3(l3, l3, l3), c, 1.0 + vib);

    // Light glow: a wider blur of the bright areas, screen-blended
    float glowAmount = NL_Glow * NL_Master;
    if (glowAmount > 0.0)
    {
        float2 qp = float2(3.0 / NL_QUART_W, 3.0 / NL_QUART_H);
        float3 wide = (large + tex2D(NL_Large, uv + qp).rgb + tex2D(NL_Large, uv - qp).rgb
                     + tex2D(NL_Large, uv + float2(qp.x, -qp.y)).rgb + tex2D(NL_Large, uv + float2(-qp.x, qp.y)).rgb) * 0.2;
        float3 glow = wide * smoothstep(NL_GlowThreshold, NL_GlowThreshold + 0.25, NL_Luma(wide)) * glowAmount;
        c = 1.0 - (1.0 - saturate(c)) * (1.0 - saturate(glow));
    }

    // Mood colour grade
    c = NL_ApplyMood(saturate(c), NL_MoodStrength * saturate(NL_Master), skin);

    // Vignette
    float2 vc = (uv - 0.5) * float2(BUFFER_ASPECT_RATIO, 1.0);
    float vr = length(vc) / length(float2(BUFFER_ASPECT_RATIO, 1.0) * 0.5);
    c *= 1.0 - NL_Vignette * NL_Master * 0.6 * smoothstep(0.45, 1.15, vr);

    // Film grain, strongest in the mid-tones
    float grainAmount = NL_Grain * NL_Master;
    if (grainAmount > 0.0)
    {
        float lg = saturate(NL_Luma(c));
        float n = NL_Hash(vpos.xy + float(NL_Frame % 1024) * float2(17.13, 31.77)) - 0.5;
        c += n * grainAmount * 0.10 * (0.3 + 2.8 * lg * (1.0 - lg));
    }

    // Debug views
    if (NL_Debug == 1)
        c = float3(1.0 - occ, 1.0 - occ, 1.0 - occ);
    else if (NL_Debug == 2)
        c = lerp(float3(lumaO, lumaO, lumaO) * 0.6, float3(1.0, 0.25, 0.2), skin);
    else if (NL_Debug == 3)
    {
        float v = saturate(0.5 + ld * 4.0);
        c = float3(v, v, v);
    }
    else
    {
        // Dither to stop the contrast changes from causing banding
        c += (NL_IGN(vpos.xy) - 0.5) / 255.0;
    }

    if (NL_Compare && abs(uv.x - NL_SplitPos) < BUFFER_RCP_WIDTH * 1.5)
        c = float3(1.0, 1.0, 1.0);
    if (NL_ShowStatus && NL_OverlayOpen)
        c = NL_DrawStatus(uv, saturate(c), depthState);

    return float4(saturate(c), 1.0);
}

// ---------------------------------------------------------------------------

technique NeuralLook <
    ui_label = "NeuralLook";
    ui_tooltip = "A neural-rendering-inspired look made with ordinary shaders:\nlighting contrast, material detail, shadows, skin light wrap, mood grades and light glow.\nNo AI model. Built for GTX 1650-class GPUs.";
>
{
    pass Down    { VertexShader = PostProcessVS; PixelShader = PS_NL_Down;   RenderTarget = NL_HalfTex; }
    pass SmallH  { VertexShader = PostProcessVS; PixelShader = PS_NL_SmallH; RenderTarget = NL_BlurATex; }
    pass SmallV  { VertexShader = PostProcessVS; PixelShader = PS_NL_SmallV; RenderTarget = NL_SmallTex; }
    pass DownQ   { VertexShader = PostProcessVS; PixelShader = PS_NL_DownQ;  RenderTarget = NL_QuartTex; }
    pass LargeH  { VertexShader = PostProcessVS; PixelShader = PS_NL_LargeH; RenderTarget = NL_QBlurATex; }
    pass LargeV  { VertexShader = PostProcessVS; PixelShader = PS_NL_LargeV; RenderTarget = NL_LargeTex; }
#if NL_CONTACT_SHADOWS
    pass DepthCheck { VertexShader = PostProcessVS; PixelShader = PS_NL_DepthCheck; RenderTarget = NL_StateTex; }
    pass StateCopy  { VertexShader = PostProcessVS; PixelShader = PS_NL_StateCopy;  RenderTarget = NL_StatePrevTex; }
    pass AO      { VertexShader = PostProcessVS; PixelShader = PS_NL_AO;      RenderTarget = NL_AOTex; }
    pass AOBlurH { VertexShader = PostProcessVS; PixelShader = PS_NL_AOBlurH; RenderTarget = NL_AOBlurTex; }
    pass AOBlurV { VertexShader = PostProcessVS; PixelShader = PS_NL_AOBlurV; RenderTarget = NL_AOTex; }
#endif
    pass Final   { VertexShader = PostProcessVS; PixelShader = PS_NL_Composite; }
}
