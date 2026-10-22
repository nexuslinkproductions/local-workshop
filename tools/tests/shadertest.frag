#version 440

// ShaderEffect fragment shader: diagonal gradient plus one round dot.
// Baked with tools/qsb.sh (GLSL 100 es/120/150, HLSL 50, MSL 12).

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float phase;
    float u_width;
    float u_height;
};

void main()
{
    vec2 uv = qt_TexCoord0;

    vec3 low = vec3(0.04, 0.06, 0.11);
    vec3 high = vec3(0.10, 0.42, 0.80);
    vec3 col = mix(low, high, clamp(uv.x * 0.65 + uv.y * 0.35, 0.0, 1.0));

    float aspect = u_width / max(u_height, 1.0);
    float cx = 0.5 + (phase - 0.5) * 0.10;
    vec2 p = vec2((uv.x - cx) * aspect, uv.y - 0.45);
    float d = length(p);
    float dotMask = smoothstep(0.125, 0.110, d);
    col = mix(col, vec3(0.78, 0.95, 0.11), dotMask);

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
