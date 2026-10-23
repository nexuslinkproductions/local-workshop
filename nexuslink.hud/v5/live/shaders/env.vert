#version 440

// Environment slot, vertex stage: one quad over the item. Texture coordinates run
// 0..1 over the item with (0,0) at the top left; the fragment stage turns them into
// global desktop pixels. The uniform block is the same as in env.frag (Qt shares one
// uniform buffer between the two stages), so the members and their order must match.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 origin;
    vec4 world;
    vec2 itemSize;
    float t;
    vec2 par;
    float link;
    float ai;
    vec4 bayA;
    vec4 bayB;
    vec2 disk;
    vec4 baseColor;
    float debugGrid;
};

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
