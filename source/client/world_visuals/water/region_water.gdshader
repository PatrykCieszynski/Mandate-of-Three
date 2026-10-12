shader_type spatial;
render_mode cull_back, depth_draw_never, diffuse_burley, specular_schlick_ggx;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D ripple_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec3 shallow_color : source_color = vec3(0.12, 0.37, 0.36);
uniform vec3 deep_color : source_color = vec3(0.014, 0.075, 0.12);
uniform vec3 foam_color : source_color = vec3(0.65, 0.73, 0.7);
uniform float absorption : hint_range(0.1, 3.0) = 0.65;
uniform float wave_strength : hint_range(0.0, 1.0) = 1.0;
uniform float normal_strength : hint_range(0.0, 0.5) = 0.16;
uniform float refraction_strength : hint_range(0.0, 0.02) = 0.003;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.65;
uniform float surface_time = 0.0;
uniform vec2 detail_fade = vec2(18.0, 70.0);
varying vec3 surface_world;
varying vec3 surface_normal;

// Small lake waves. Sum of horizontal steepness stays safely below one.
vec3 gerstner(vec2 direction, float wavelength, float amplitude, float speed,
        vec2 point, inout vec3 tangent_x, inout vec3 tangent_z) {
    vec2 d = normalize(direction);
    float k = 6.2831853 / wavelength;
    float phase = k * dot(d, point) - speed * surface_time;
    float a = amplitude * wave_strength;
    float qa = a * 0.35;
    float s = sin(phase);
    float c = cos(phase);
    tangent_x += vec3(-qa*k*d.x*d.x*s, a*k*d.x*c, -qa*k*d.x*d.y*s);
    tangent_z += vec3(-qa*k*d.x*d.y*s, a*k*d.y*c, -qa*k*d.y*d.y*s);
    return vec3(qa*d.x*c, a*s, qa*d.y*c);
}

void vertex() {
    vec2 point = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
    vec3 tx = vec3(1.0, 0.0, 0.0);
    vec3 tz = vec3(0.0, 0.0, 1.0);
    vec3 displacement = gerstner(vec2(1.0, 0.35), 7.0, 0.045, 1.3, point, tx, tz);
    displacement += gerstner(vec2(-0.3, 1.0), 3.8, 0.025, 1.7, point, tx, tz);
    displacement += gerstner(vec2(0.6, -0.8), 2.2, 0.012, 2.1, point, tx, tz);
    VERTEX += displacement;
    NORMAL = normalize(cross(tz, tx));
    surface_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
    surface_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec3 view_position(vec2 uv, float depth, mat4 inverse_projection) {
    // Forward+/Vulkan reverse-Z: NDC z is already in [0,1].
    vec4 p = inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
    return p.xyz / p.w;
}

void fragment() {
    float distance_to_eye = length(VERTEX);
    float detail = 1.0 - smoothstep(detail_fade.x, detail_fade.y, distance_to_eye);
    vec2 uv1 = surface_world.xz * 0.45 + vec2(0.022, 0.012) * surface_time;
    vec2 uv2 = surface_world.xz * 0.72 + vec2(-0.013, 0.018) * surface_time;
    vec2 ripple = ((texture(ripple_normal, uv1).rg * 2.0 - 1.0)
        + (texture(ripple_normal, uv2).rg * 2.0 - 1.0)) * normal_strength * detail;
    vec3 n = normalize(surface_normal + vec3(ripple.x, 0.0, ripple.y));
    NORMAL = normalize(mat3(VIEW_MATRIX) * n);
    float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);
    float raw_depth = texture(scene_depth, SCREEN_UV).r;
    vec3 behind = view_position(SCREEN_UV, raw_depth, INV_PROJECTION_MATRIX);
    vec3 behind_world = (INV_VIEW_MATRIX * vec4(behind, 1.0)).xyz;
    float thickness = max(surface_world.y - behind_world.y, 0.0);
    float depth_mix = 1.0 - exp(-thickness * absorption);
    vec3 water_color = mix(shallow_color, deep_color, depth_mix);

    // Distortion tap must still be behind this surface (no foreground halos).
    vec2 offset = NORMAL.xy * refraction_strength * detail * smoothstep(0.0, 0.6, thickness);
    vec2 refracted_uv = clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999));
    float shifted_depth = texture(scene_depth, refracted_uv).r;
    vec3 shifted = view_position(refracted_uv, shifted_depth, INV_PROJECTION_MATRIX);
    if (-shifted.z <= -VERTEX.z + 0.03) { refracted_uv = SCREEN_UV; }
    vec3 transmitted = textureLod(scene_color, refracted_uv, 0.0).rgb;
    float transmission = exp(-thickness * absorption) * (1.0 - fresnel) * 0.65;

    // Break up the depth intersection band with the same filtered ripple map.
    float breakup = texture(ripple_normal, uv1 * 0.65).r;
    float foam = (1.0 - smoothstep(0.04, 0.40 + breakup * 0.15, thickness))
        * smoothstep(0.32, 0.58, breakup) * foam_strength;
    ALBEDO = mix(water_color, foam_color, foam);
    // Transmission is already lit scene radiance; do not light it a second time.
    ALBEDO *= 1.0 - transmission;
    EMISSION = transmitted * transmission * (1.0 - foam);
    METALLIC = 0.0;
    SPECULAR = 0.25; // Water's dielectric F0 = 0.02; engine supplies sky and V2 lights.
    ROUGHNESS = mix(0.12, 0.24, 1.0 - detail) + foam * 0.35;
}
