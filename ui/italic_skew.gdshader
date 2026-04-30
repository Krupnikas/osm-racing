// italic_skew.gdshader — applies a CSS-style skewX to a Label uniformly,
// so all glyph vertices shift together. Bypasses the per-glyph rotation
// artifact of FontVariation.variation_transform.
//
// Apply via ShaderMaterial on Label.material. The label height comes from
// the Label's bounding box (top y=0, bottom y=size.y), so shear is anchored
// at the bottom (baseline-ish).
shader_type canvas_item;

uniform float shear : hint_range(-1.0, 1.0) = 0.213;
uniform float ref_height : hint_range(1.0, 400.0) = 132.0;

void vertex() {
	// VERTEX.y in label-local coords: 0 at top, ref_height at bottom.
	// For italic right-lean: top shifts right, bottom stays.
	VERTEX.x += shear * (ref_height - VERTEX.y);
}
