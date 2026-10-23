#version 440

// Probe 1: does a ShaderEffect sampler carry the PNG bytes unchanged, and is
// texel (0,0) at uv (0,0) or flipped? The QML samples four known texels of the
// data texture and paints them as four quadrants, so one still answers both
// questions: read the quadrant colours and compare with the PNG bytes.
// Texture size comes in as a uniform: textureSize() does not exist in ESSL 100.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_texSize;
    float u_pickX;
    float u_pickY;
};

layout(binding = 1) uniform sampler2D u_tex;

void main()
{
    vec2 q = step(vec2(0.5), qt_TexCoord0);      // 0 = left/top, 1 = right/bottom
    vec2 pick = mix(vec2(3.5, 3.5), vec2(u_pickX, u_pickY), q);
    vec4 t = texture(u_tex, pick / u_texSize);
    float byte = floor(t.r * 255.0 + 0.5);
    fragColor = vec4(byte / 255.0, t.r, t.g, 1.0);
}
