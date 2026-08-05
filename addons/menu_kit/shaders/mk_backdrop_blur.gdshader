shader_type canvas_item;

// Vendored MenuKit backdrop shader (plan §1.1: the source preloaded a shader living outside the UI
// tree; the addon must reference nothing outside res://addons/menu_kit/).
//
// Soft 5x5 box blur plus an optional horizontal drift. blur_amount is the per-tap offset in pixels,
// so the effective radius is ~2 * blur_amount; it lets a sharp screenshot be used as a soft menu
// backdrop without pre-blurring the asset.
//
// The blur averages in LINEAR light (decode sRGB -> average -> re-encode). Averaging in gamma space
// underestimates the average across pixels of differing brightness and visibly darkens
// high-contrast content — that was a real "the blur dims the background" bug in the source project.
//
// Uses only core canvas_item builtins (TEXTURE, UV, TEXTURE_PIXEL_SIZE, COLOR) and a constant loop
// bound, so it compiles on Forward+, Mobile, and Compatibility alike.

uniform float blur_amount : hint_range(0.0, 16.0) = 0.0;
// Accumulated horizontal offset in UV units, advanced by MKBackdrop from the def's scroll_speed.
// Wrapping is done with fract(), which requires the host CanvasItem to enable texture repeat;
// MKBackdrop sets that whenever scroll is non-zero.
uniform float scroll_offset = 0.0;

vec3 mk_to_linear(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

vec3 mk_to_srgb(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}

void fragment() {
	vec2 base_uv = vec2(fract(UV.x + scroll_offset), UV.y);
	if (blur_amount <= 0.001) {
		COLOR = texture(TEXTURE, base_uv) * COLOR;
	} else {
		vec2 ps = TEXTURE_PIXEL_SIZE * blur_amount;
		vec3 lin_sum = vec3(0.0);
		float alpha_sum = 0.0;
		for (int x = -2; x <= 2; x++) {
			for (int y = -2; y <= 2; y++) {
				vec4 s = texture(TEXTURE, base_uv + vec2(float(x), float(y)) * ps);
				lin_sum += mk_to_linear(s.rgb);
				alpha_sum += s.a;
			}
		}
		vec3 blurred = mk_to_srgb(lin_sum / 25.0);
		COLOR = vec4(blurred, alpha_sum / 25.0) * COLOR;
	}
}
