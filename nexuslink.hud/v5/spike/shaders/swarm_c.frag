#version 440

// Swarm option C: one quad, no vertex geometry. Every fragment looks up its own
// object-space cell in the data texture and tests the dots of the 3x3 cell
// neighbourhood, so a dot that projects anywhere near a pixel is found by a
// neighbour lookup rather than by rasterised geometry. The cell lists are baked
// per lattice cell (swarm-knot-cells.png, one row per cell) and the count comes
// from swarm-knot-cellcount.png; alpha stays 255 in both because Qt
// premultiplies image textures.
//
// Cost is the count of dots in the 3x3 neighbourhood: dense cells cost more,
// which is exactly the trade the spike has to measure.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

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
    vec4 u_texInfo;         // x = cols, y = rows, z = kmax, w = cell count
    vec4 u_cellInfo;        // xy = cell origin, z = cell size
    vec2 u_cellN;
};

layout(binding = 1) uniform sampler2D u_pts;
layout(binding = 2) uniform sampler2D u_counts;

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

void main()
{
    vec2 px = vec2(qt_TexCoord0.x - 0.5, 0.5 - qt_TexCoord0.y) * u_size;
    mat3 R = rotMat(u_yaw, u_tilt);

    // invert the projection at z = 0 to find this fragment's cell
    vec2 po = (transpose(R) * vec3(px / u_pxPerUnit, 0.0)).xy;
    vec2 cell = floor((po - u_cellInfo.xy) / u_cellInfo.z);
    if (cell.x < -0.5 || cell.y < -0.5 || cell.x > u_cellN.x - 0.5 || cell.y > u_cellN.y - 0.5) {
        fragColor = vec4(0.0);
        return;
    }

    float bestDepth = -1e9;
    vec3 bestCol = vec3(0.0);
    float bestMask = 0.0;
    float nCells = u_cellN.x * u_cellN.y;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            vec2 c = cell + vec2(float(dx), float(dy));
            if (c.x < 0.0 || c.y < 0.0 || c.x > u_cellN.x - 1.0 || c.y > u_cellN.y - 1.0)
                continue;
            float count = floor(texture(u_counts, (c + 0.5) / u_cellN).r * 255.0 + 0.5);
            float row = c.y * u_cellN.x + c.x;
            float v = (row + 0.5) / nCells;
            for (int k = 0; k < 128; ++k) {
                if (float(k) >= count)
                    break;
                vec4 t = texture(u_pts, vec2((float(k) + 0.5) / u_texInfo.z, v));
                if (t.r > 0.996)
                    continue;
                vec3 p = u_posBase + floor(t.rgb * 255.0 + 0.5) * u_pitch;
                vec3 vr = R * p;
                float s = u_pxPerUnit * u_camDist / max(u_camDist - vr.z, 0.05);
                float radius = max(0.45, u_dotR * s);
                float aa = clamp(radius * 0.42, 0.45, 1.1);
                float mask = 1.0 - smoothstep(radius - aa, radius + aa * 0.25,
                                             length(vr.xy * s - px));
                if (mask <= 0.002 || vr.z <= bestDepth)
                    continue;
                bestDepth = vr.z;
                bestMask = mask;
                float depth = clamp(0.5 + vr.z / max(2.0 * u_rTube, 1e-4) * 0.5, 0.0, 1.0);
                float j = fract(sin(dot(vec2(row, float(k)), vec2(12.9898, 78.233))) * 43758.5453);
                float bright = mix(0.42, 1.0, depth * depth) * mix(0.74, 1.14, j);
                bright *= mix(1.0, 1.12, u_activity) * (1.0 - 0.55 * u_focus) * u_gain;
                vec3 col = mix(u_accent.rgb * 0.55, u_accent.rgb, depth);
                col = mix(col, vec3(1.0), pow(depth, 4.0) * 0.22);
                bestCol = col * bright;
            }
        }
    }

    fragColor = vec4(bestCol, bestMask);
}
