shader_type canvas_item;

// Vendored MenuKit gamma shader — the default brightness implementation (plan §4.3).
//
// Godot 4.7 exposes no global or OS gamma control, so a brightness slider has to be drawn. This is
// the whole implementation: read what has already been rendered and re-encode it with a different
// gamma. Applied by MKBrightnessController through a full-rect ColorRect on a very high CanvasLayer,
// so it affects the UI as well as the world — which is what the "adjust until the logo is barely
// visible" calibration convention requires, and what makes it renderer-independent.
//
// gamma > 1 lifts the image, gamma < 1 darkens it; 1.0 is exactly neutral (pow(c, 1.0) == c), and
// at that value the controller hides the overlay entirely so the neutral case costs zero fullscreen
// texture reads.
//
// Uses only core canvas_item builtins (a screen texture, SCREEN_UV, COLOR), so it compiles on
// Forward+, Mobile and Compatibility alike. Alpha is forced to 1.0: this quad REPLACES what is
// behind it with a re-encoded copy rather than blending over it, so any alpha < 1 would blend the
// corrected image back against the uncorrected one and halve the effect.
uniform sampler2D mk_screen : hint_screen_texture, filter_linear;
uniform float gamma : hint_range(0.1, 4.0) = 1.0;

void fragment() {
	vec3 c = texture(mk_screen, SCREEN_UV).rgb;
	COLOR = vec4(pow(max(c, vec3(0.0)), vec3(1.0 / max(gamma, 0.001))), 1.0);
}
