#version 440

// Vertex texture fetch test, fragment stage.
// Soft disc inside the quad, and the bridge-cell discard: vFlat (flat) and
// vSmooth (smooth) hold the same point index, so they agree inside a quad and
// differ across the bridge triangles a GridMesh inserts between cells.

layout(location = 0) in vec2 vLocal;
layout(location = 1) flat in float vFlat;
layout(location = 2) in float vSmooth;

layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_grid;
    vec2 u_dataSize;
    vec2 u_size;
    vec2 u_center;
    float u_radius;
    float u_pointPx;
    vec4 u_color;
};

void main()
{
    if (abs(vFlat - vSmooth) > 0.001)
        discard;

    float d = length(vLocal - vec2(0.5));
    float a = smoothstep(0.5, 0.30, d);
    if (a <= 0.001)
        discard;

    fragColor = vec4(u_color.rgb, u_color.a * a) * qt_Opacity;
}
