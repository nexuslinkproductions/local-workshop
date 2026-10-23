#version 440

layout(location = 0) in vec2 v_local;
layout(location = 1) in float v_radius;
layout(location = 2) in vec4 v_color;
layout(location = 3) in float v_pidSmooth;
layout(location = 4) in float v_spark;

layout(location = 0) out vec4 fragColor;

// Same block as the vertex stage: Qt shares one uniform buffer between the
// two stages, so the member order and types must match exactly.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float uN;
    float uWidth;
    float uRows;
    float t;
    float knotPx;
    float uW;
    float uH;
    float uOffset;
    vec4 uSparkCol;
    vec4 uSparkGeom;
};

layout(binding = 1) uniform sampler2D src;

void main() {
    // bridges between neighbouring points carry two different ids
    if (abs(v_pidSmooth - floor(v_pidSmooth + 0.5)) > 0.01) discard;

    // K3c: acid spark disc, solid core, 1 px soft edge, drawn last (source-over)
    if (v_spark > 0.5) {
        float rs = length(v_local);
        float cs = 1.0 - smoothstep(v_radius - 1.0, v_radius, rs);
        if (cs < 0.002) discard;
        float as = clamp(cs * qt_Opacity, 0.0, 1.0);
        fragColor = vec4(v_color.rgb * as, as);
        return;
    }

    float r = length(v_local);
    float cover = 1.0 - smoothstep(v_radius - 1.0, v_radius, r);
    if (cover < 0.002) discard;
    if (v_color.a < 0.004) discard;

    // K3b: source-over (premultiplied). Stacked dots converge to the dot colour
    // instead of adding up, so the core cannot clip and an acid spark stays acid.
    // Was additive (alpha 0), which summed 10 layers to white at the sparks.
    float a = clamp(v_color.a * cover * qt_Opacity, 0.0, 1.0);
    fragColor = vec4(v_color.rgb * a, a);
    // keep the point-data sampler bound in the fragment stage as well, so the
    // binding is visible to both stages (never true at run time)
    if (v_pidSmooth < -1.0) fragColor.r = texture(src, vec2(0.5)).r;
}
