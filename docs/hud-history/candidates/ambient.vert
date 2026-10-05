#version 440

// Qt6 ShaderEffect default quad-grid vertex stage, declared explicitly so
// the fragment stage's `qt_TexCoord0` input has a real matching output on
// every RHI backend (some built-in vertex-shader paths produce no varying,
// which triggered the journal link warning).
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
