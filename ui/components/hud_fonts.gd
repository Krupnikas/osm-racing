extends RefCounted

## Shared font helpers for the new HUD components. JetBrainsMono ships as
## a Variable Font (`JetBrainsMono-VariableFont_wght.ttf`); Godot 4 needs
## a `FontVariation` wrapper to render variable fonts via
## `add_theme_font_override` — without one the renderer falls back to its
## built-in face and Cyrillic glyphs end up looking like the default font.
##
## ShareTechMono-Regular ships latin-only, so Cyrillic captions (which is
## most of our UI text) need a font that actually has Cyrillic glyphs —
## JetBrainsMono is the right pick.
##
## All getters return cached resources, so it is safe to call them from
## every component's `_apply_theme()` without paying repeated load cost.

class_name HudFonts

const _JB_BASE := preload("res://ui/fonts/JetBrainsMono-VariableFont_wght.ttf")

static var _jb_regular: FontVariation
static var _jb_bold: FontVariation


static func jbmono_regular() -> Font:
	if _jb_regular == null:
		var fv := FontVariation.new()
		fv.base_font = _JB_BASE
		fv.variation_opentype = {&"wght": 400}
		_jb_regular = fv
	return _jb_regular


static func jbmono_bold() -> Font:
	if _jb_bold == null:
		var fv := FontVariation.new()
		fv.base_font = _JB_BASE
		fv.variation_opentype = {&"wght": 700}
		_jb_bold = fv
	return _jb_bold
