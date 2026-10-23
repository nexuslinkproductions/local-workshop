#version 440

// Vertex texture fetch test, vertex stage.
// One GridMesh cell per data point: the cell corner (qt_MultiTexCoord0) is
// turned into a point index, the data texture is sampled here in the VERTEX
// stage with textureLod, and the decoded position places a small quad.
//
// A GridMesh is one triangle strip, so neighbouring quads are joined by
// bridge triangles. vFlat carries the point index flat (provoking vertex) and
// vSmooth interpolates it; the fragment stage discards wherever they differ,
// which removes exactly the bridge cells.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;

layout(location = 0) out vec2 vLocal;
layout(location = 1) flat out float vFlat;
layout(location = 2) out float vSmooth;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_grid;        // mesh resolution, for example (64, 1)
    vec2 u_dataSize;    // data texture size in texels, for example (64, 1)
    vec2 u_size;        // output size in pixels
    vec2 u_center;      // circle centre in pixels
    float u_radius;     // circle radius in pixels
    float u_pointPx;    // quad edge in pixels
    vec4 u_color;       // unused here, keeps the block identical to the fragment stage
};

layout(binding = 1) uniform sampler2D u_data;

void main()
{
    vec2 cell = floor(qt_MultiTexCoord0 * u_grid);
    cell = clamp(cell, vec2(0.0), u_grid - vec2(1.0));
    float index = cell.y * u_grid.x + cell.x;

    // Centre of the texel that holds this point. nearest filtering means the
    // value is exact, no bleed from the neighbouring texel.
    vec2 dataUv = (vec2(mod(index, u_dataSize.x), floor(index / u_dataSize.x)) + vec2(0.5))
                  / u_dataSize;
    vec4 data = textureLod(u_data, dataUv, 0.0);

    // data.rg = position on the unit circle in [0,1]; decode to pixels.
    vec2 anchor = u_center + (data.rg * 2.0 - 1.0) * u_radius;

    vec2 corner = fract(qt_MultiTexCoord0 * u_grid) - vec2(0.5);
    vec2 pos = anchor + corner * u_pointPx;

    vLocal = fract(qt_MultiTexCoord0 * u_grid);
    vFlat = index;
    vSmooth = index;

    gl_Position = qt_Matrix * vec4(pos, 0.0, 1.0);
}
