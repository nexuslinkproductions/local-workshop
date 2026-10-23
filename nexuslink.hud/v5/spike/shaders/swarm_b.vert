#version 440

// Swarm option B, vertex stage: one GridMesh vertex per dot. The vertex reads
// its point from the data texture (integer lattice index, alpha 255 because Qt
// premultiplies image textures), rotates it in 3D, projects it with perspective
// and passes its item-local pixel position plus the mesh uv to the fragment
// stage. The fragment tests the four dots around each cell, so every dot is
// drawn by the union of its four surrounding quads and stays round.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_TexCoord0;
layout(location = 0) out vec2 vUV;
layout(location = 1) out vec2 vScreen;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;
    float u_pxPerUnit;
    vec4 u_accent;
    vec3 u_posBase;
    float u_pitch;
    float u_dotR;
    float u_rTube;
    float u_yaw;
    float u_tilt;
    float u_camDist;
    float u_gain;
    float u_focus;
    float u_activity;
    vec4 u_texInfo;         // x = cols, y = rows, z = kmax
    vec4 u_cellInfo;        // xy = cell origin, z = cell size
    vec2 u_cellN;
};

layout(binding = 1) uniform sampler2D u_pts;

mat3 rotMat(float yaw, float tilt)
{
    float cy = cos(yaw), sy = sin(yaw);
    float ct = cos(tilt), st = sin(tilt);
    mat3 ry = mat3(cy, 0.0, -sy,
                   0.0, 1.0, 0.0,
                   sy, 0.0, cy);
    mat3 rx = mat3(1.0, 0.0, 0.0,
                   0.0, ct, st,
                   0.0, -st, ct);
    return ry * rx;
}

vec3 decode(vec4 t)
{
    if (t.r > 0.996)
        return vec3(0.0);                   // padding marker, hidden by a zero size
    vec3 q = floor(t.rgb * 255.0 + 0.5);
    return u_posBase + q * u_pitch;
}

void main()
{
    vec2 uv = qt_TexCoord0;
    vec2 texel = (uv * u_texInfo.xy + 0.5) / u_texInfo.xy;
    vec3 p = decode(texture(u_pts, texel));
    vec3 v = rotMat(u_yaw, u_tilt) * p;
    float s = u_pxPerUnit * u_camDist / max(u_camDist - v.z, 0.05);
    vec2 px = v.xy * s;
    vScreen = vec2(u_size.x * 0.5 + px.x, u_size.y * 0.5 - px.y);
    vUV = uv;
    gl_Position = qt_Matrix * vec4(vScreen, 0.0, 1.0);
}
