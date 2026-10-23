/*
    NeuralLook.fx  v0.1.0
    https://github.com/GalileoHanx/NeuralLook  -  MIT License

    A neural-rendering-inspired look for GPUs without tensor cores.
    Built and tuned for GTX 1650-class cards. ReShade 5.0 or newer.
    Not affiliated with or endorsed by NVIDIA.

    This is NOT neural rendering. No AI model runs here. It imitates the parts of
    the DLSS 5 look that ordinary shader math can fake:

      Phase 1  Core look        local lighting contrast, material micro-detail,
                                highlights that pick up surface texture, gentle filmic tone
      Phase 2  Contact shadows  small-radius depth shadows in creases, joints and where
                                objects meet (needs ReShade depth access)
      Phase 3  Skin             warm, subsurface-style light wrap at the light/shadow edge
                                plus pore-level detail on skin tones
      Phase 4  Tuning           Light / Balanced / Strong presets, split-screen compare,
                                debug views

    Cost: blurs run at half and quarter resolution, shadows at half resolution.
    Built for SDR. Put it after the game's own anti-aliasing (ReShade runs after the
    game renders, so this is the default).

    Preprocessor switches (edit them in ReShade under this effect's settings):
      NL_CONTACT_SHADOWS  1 = on, 0 = off (skips all depth passes; use it when
                          the game's depth buffer is unavailable)
      NL_SKIN             1 = on, 0 = off
      NL_AO_SAMPLES       4 = fastest, 8 = default, 12 = smoother shadows
*/

#include "ReShade.fxh"

#ifndef NL_CONTACT_SHADOWS
    #define NL_CONTACT_SHADOWS 1
#endif
#ifndef NL_SKIN
    #define NL_SKIN 1
#endif
#ifndef NL_AO_SAMPLES
    #define NL_AO_SAMPLES 8
#endif

#ifdef BUFFER_COLOR_SPACE
    #if BUFFER_COLOR_SPACE > 1
        #warning "NeuralLook is tuned for SDR. Turn HDR off in the game for correct colours."
    #endif
#endif

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

uniform int NL_Preset <
    ui_type = "combo";
    ui_items = "Custom (use the sliders below)\0Light\0Balanced\0Strong\0";
    ui_label = "Look preset";
    ui_tooltip = "Light, Balanced and Strong ignore the Custom sliders.\nChoose Custom to tune each effect by hand.";
> = 2;

uniform float NL_Master <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Overall strength";
    ui_tooltip = "Scales every effect, whichever preset is active.";
> = 1.0;

// Custom sliders ------------------------------------------------------------

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
    ui_category = "Custom: contact shadows and skin"; ui_category_closed = true;
    ui_label = "Contact shadow strength";
> = 0.55;

uniform float NL_SSS <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: contact shadows and skin"; ui_category_closed = true;
    ui_label = "Skin light wrap";
    ui_tooltip = "Warm light bleeding into the shadow side of skin, like subsurface scattering.";
> = 0.40;

uniform float NL_SkinDetail <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Custom: contact shadows and skin"; ui_category_closed = true;
    ui_label = "Skin detail";
    ui_tooltip = "Adds variation and pore-level texture to skin so it looks less waxy.";
> = 0.35;

// Scene settings (used by every preset) ---------------------------------------

uniform float NL_AORadius <
    ui_type = "slider"; ui_min = 0.05; ui_max = 3.0; ui_step = 0.01;
    ui_category = "Scene settings";
    ui_label = "Contact shadow radius";
    ui_tooltip = "Size of the shadowed area around creases and contact points.\nGame units differ, so raise it if shadows are too thin, lower it if they look like dark halos.";
> = 0.5;

uniform float NL_AOFade <
    ui_type = "slider"; ui_min = 0.02; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Scene settings";
    ui_label = "Contact shadow distance";
    ui_tooltip = "How far into the scene shadows are drawn (fraction of depth range).";
> = 0.3;

uniform float NL_FovDeg <
    ui_type = "slider"; ui_min = 50.0; ui_max = 110.0; ui_step = 1.0;
    ui_category = "Scene settings";
    ui_label = "Game vertical field of view";
    ui_tooltip = "Roughly match the game's FOV so shadow shapes come out right.";
> = 70.0;

uniform float NL_SkinRange <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_category = "Scene settings";
    ui_label = "Skin detection width";
    ui_tooltip = "Lower it if wood, sand or brick get treated as skin (check with the Skin mask debug view).";
> = 1.0;

// Compare and debug -------------------------------------------------------------

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
    ui_items = "Off\0Contact shadows\0Skin mask\0Lighting contrast\0";
    ui_category = "Compare and debug";
    ui_label = "Debug view";
> = 0;

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
texture NL_AOTex     { Width = NL_HALF_W; Height = NL_HALF_H; Format = R16F; };
texture NL_AOBlurTex { Width = NL_HALF_W; Height = NL_HALF_H; Format = R16F; };
sampler NL_AO     { Texture = NL_AOTex; };
sampler NL_AOBlur { Texture = NL_AOBlurTex; };
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
    float sss;
    float skinDetail;
};

NLParams NL_GetParams()
{
    NLParams p;
    if (NL_Preset == 1)      // Light
    {
        p.clarity = 0.25; p.detail = 0.25; p.highlight = 0.20; p.tone = 0.15;
        p.vibrance = 0.05; p.ao = 0.35; p.sss = 0.25; p.skinDetail = 0.20;
    }
    else if (NL_Preset == 2) // Balanced
    {
        p.clarity = 0.45; p.detail = 0.40; p.highlight = 0.35; p.tone = 0.25;
        p.vibrance = 0.10; p.ao = 0.55; p.sss = 0.40; p.skinDetail = 0.35;
    }
    else if (NL_Preset == 3) // Strong
    {
        p.clarity = 0.70; p.detail = 0.60; p.highlight = 0.50; p.tone = 0.40;
        p.vibrance = 0.15; p.ao = 0.80; p.sss = 0.55; p.skinDetail = 0.50;
    }
    else                     // Custom
    {
        p.clarity = NL_Clarity; p.detail = NL_Detail; p.highlight = NL_Highlight; p.tone = NL_Tone;
        p.vibrance = NL_Vibrance; p.ao = NL_AOStrength; p.sss = NL_SSS; p.skinDetail = NL_SkinDetail;
    }

    p.clarity *= NL_Master; p.detail *= NL_Master; p.highlight *= NL_Master; p.tone *= NL_Master;
    p.vibrance *= NL_Master; p.ao *= NL_Master; p.sss *= NL_Master; p.skinDetail *= NL_Master;
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
// Phase 1 passes: downsample and blur pyramid
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
// Phase 2 passes: contact shadows
// ---------------------------------------------------------------------------

#if NL_CONTACT_SHADOWS

float3 NL_ViewPos(float2 uv, float tanHalf)
{
    float z = ReShade::GetLinearizedDepth(uv) * RESHADE_DEPTH_LINEARIZATION_FAR_PLANE;
    float2 ndc = uv * 2.0 - 1.0;
    return float3(ndc * float2(BUFFER_ASPECT_RATIO, 1.0) * tanHalf * z, z);
}

float4 PS_NL_AO(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float zN = ReShade::GetLinearizedDepth(uv);
    // No depth (blank buffer), first-person weapon too close, or sky: no shadow
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

    float noise = NL_IGN(vpos.xy);
    float occ = 0.0;

    [unroll]
    for (int i = 0; i < NL_AO_SAMPLES; i++)
    {
        float t = (i + 0.5) / NL_AO_SAMPLES;
        float a = (i + noise) * 2.39996323;            // golden-angle spiral
        float r = sqrt(t) * radiusPx;
        float2 suv = uv + float2(cos(a), sin(a)) * r * BUFFER_PIXEL_SIZE;
        float3 v = NL_ViewPos(suv, tanHalf) - p;
        float d2 = dot(v, v);
        occ += saturate(dot(n, v) * rsqrt(d2 + 1e-6) - 0.15) * saturate(1.0 - d2 / R2);
    }

    occ = saturate(occ / NL_AO_SAMPLES * 4.0);
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
// Final composite: phases 1-4
// ---------------------------------------------------------------------------

float4 PS_NL_Composite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;

    // Phase 4: split-screen compare (right side shows the untouched game)
    if (NL_Compare)
    {
        if (abs(uv.x - NL_SplitPos) < BUFFER_RCP_WIDTH)
            return float4(1.0, 1.0, 1.0, 1.0);
        if (uv.x > NL_SplitPos)
            return float4(orig, 1.0);
    }

    NLParams P = NL_GetParams();

    float3 small = tex2D(NL_Small, uv).rgb;
    float3 large = tex2D(NL_Large, uv).rgb;
    float lumaO = NL_Luma(orig);
    float lumaS = NL_Luma(small);
    float lumaL = NL_Luma(large);

    float3 c = orig;

    // Phase 3a: skin light wrap. Light from the lit side bleeds into the shadow side,
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

    // Phase 1a: adaptive micro-detail (contrast-adaptive, so noise and flat areas stay calm)
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

    // Phase 1b: textured highlights + Phase 3b: skin variation (mid-frequency detail)
    float midF = lumaO - lumaS;
    float highlight = midF * smoothstep(0.55, 0.95, lumaO) * P.highlight * 1.5;
    float skinVar = midF * skin * P.skinDetail * 1.5;

    // Phase 1c: local lighting contrast. Soft-limited, and eased off next to strong
    // edges (where the small and large blurs disagree) so objects don't get dark outlines.
    float ld = lumaO - lumaL;
    ld = ld / (1.0 + abs(ld) * 4.0);
    float midMask = smoothstep(0.0, 0.2, lumaO) * (1.0 - smoothstep(0.8, 1.0, lumaO));
    float edge = saturate(abs(lumaS - lumaL) * 6.0);
    float contrast = ld * midMask * (1.0 - 0.75 * edge) * P.clarity * 1.5;

    c = NL_ApplyLuma(c, detail + highlight + skinVar + contrast);

    // Phase 2: contact shadows, lighter on highlights, warmer on skin
    float occ = 0.0;
#if NL_CONTACT_SHADOWS
    occ = NL_AOUpsample(uv, ReShade::GetLinearizedDepth(uv));
    float shade = occ * P.ao * (1.0 - 0.6 * smoothstep(0.6, 1.0, lumaO));
    float3 tint = lerp(float3(1.0, 1.0, 1.0), float3(0.65, 1.0, 1.08), skin * saturate(P.sss * 2.0));
    c *= 1.0 - shade * tint;
#endif

    // Phase 1d: gentle filmic S-curve
    float l2 = saturate(NL_Luma(c));
    float curved = l2 * l2 * (3.0 - 2.0 * l2);
    c = NL_ApplyLuma(c, (curved - l2) * P.tone);

    // Phase 1e: vibrance (protects skin and already-saturated colours)
    float l3 = NL_Luma(c);
    float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float vib = P.vibrance * (1.0 - saturate(sat)) * (1.0 - skin * 0.8);
    c = lerp(float3(l3, l3, l3), c, 1.0 + vib);

    // Phase 4: debug views
    if (NL_Debug == 1)
        return float4(1.0 - occ, 1.0 - occ, 1.0 - occ, 1.0);
    if (NL_Debug == 2)
        return float4(lerp(float3(lumaO, lumaO, lumaO) * 0.6, float3(1.0, 0.25, 0.2), skin), 1.0);
    if (NL_Debug == 3)
    {
        float v = saturate(0.5 + ld * 4.0);
        return float4(v, v, v, 1.0);
    }

    // Dither to stop the contrast changes from causing banding
    c += (NL_IGN(vpos.xy) - 0.5) / 255.0;
    return float4(saturate(c), 1.0);
}

// ---------------------------------------------------------------------------

technique NeuralLook <
    ui_label = "NeuralLook";
    ui_tooltip = "A neural-rendering-inspired look made with ordinary shaders:\nlighting contrast, material detail, contact shadows and skin light wrap.\nNo AI model. Built for GTX 1650-class GPUs.";
>
{
    pass Down    { VertexShader = PostProcessVS; PixelShader = PS_NL_Down;   RenderTarget = NL_HalfTex; }
    pass SmallH  { VertexShader = PostProcessVS; PixelShader = PS_NL_SmallH; RenderTarget = NL_BlurATex; }
    pass SmallV  { VertexShader = PostProcessVS; PixelShader = PS_NL_SmallV; RenderTarget = NL_SmallTex; }
    pass DownQ   { VertexShader = PostProcessVS; PixelShader = PS_NL_DownQ;  RenderTarget = NL_QuartTex; }
    pass LargeH  { VertexShader = PostProcessVS; PixelShader = PS_NL_LargeH; RenderTarget = NL_QBlurATex; }
    pass LargeV  { VertexShader = PostProcessVS; PixelShader = PS_NL_LargeV; RenderTarget = NL_LargeTex; }
#if NL_CONTACT_SHADOWS
    pass AO      { VertexShader = PostProcessVS; PixelShader = PS_NL_AO;      RenderTarget = NL_AOTex; }
    pass AOBlurH { VertexShader = PostProcessVS; PixelShader = PS_NL_AOBlurH; RenderTarget = NL_AOBlurTex; }
    pass AOBlurV { VertexShader = PostProcessVS; PixelShader = PS_NL_AOBlurV; RenderTarget = NL_AOTex; }
#endif
    pass Final   { VertexShader = PostProcessVS; PixelShader = PS_NL_Composite; }
}
