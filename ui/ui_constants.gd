# ui_constants.gd
# Autoloaded as `UI`. Mirrors the design system tokens.
extends Node

# ── colors ────────────────────────────────────────────────
const INK_000        := Color("#06080C")
const INK_050        := Color("#0B0E14")
const INK_100        := Color("#11151D")
const INK_200        := Color("#1A1F2B")
const INK_300        := Color("#232A39")
const INK_400        := Color("#3A4456")
const INK_500        := Color("#5A6478")
const INK_700        := Color("#A4ADBE")
const INK_900        := Color("#E8ECF3")

const NEON_CYAN      := Color("#00E7FF")
const NEON_CYAN_DIM  := Color("#008A99")
const NEON_MAGENTA   := Color("#FF2BD0")
const NEON_MAGENTA_DIM := Color("#A01880")
const NEON_LIME      := Color("#C4FF2E")
const NEON_AMBER     := Color("#FFAA1D")
const NEON_RED       := Color("#FF3050")

# HDR-bright versions for glow (modulate). Use with WorldEnvironment glow on.
const NEON_CYAN_HDR     := Color(0.0, 2.5, 2.8)
const NEON_MAGENTA_HDR  := Color(2.8, 0.5, 2.4)
const NEON_LIME_HDR     := Color(2.2, 2.8, 0.6)

# ── geometry ──────────────────────────────────────────────
const SHEAR_DEG    : float = -12.0      # parallelogram skew
const SLASH_PX     : float = 18.0       # diagonal corner cut
const FOCUS_OUTLINE: float = 2.0
const PANEL_HAIR   : float = 1.0

# ── type sizes (px at 1920×1080) ──────────────────────────
const TYPE_H1       : int = 132   # billboard
const TYPE_H2       : int = 64    # screen header
const TYPE_H3       : int = 32    # row title
const TYPE_BTN      : int = 22    # button label
const TYPE_BODY     : int = 16
const TYPE_KICKER   : int = 12    # mono labels
const TYPE_HUD_NUM  : int = 96    # speedo digits

# ── helpers ───────────────────────────────────────────────
static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)

static func glow_shadow(c: Color, size: int = 18) -> Dictionary:
	return {
		"color": Color(c.r, c.g, c.b, 0.55),
		"size": size,
	}


func _ready() -> void:
	# Register theme_type_variation -> base_type for the project theme.
	# Done at runtime so we don't depend on tres syntax for type_variations.
	var theme: Theme = load("res://ui/zhazhda_theme.tres")
	if theme:
		theme.set_type_variation(&"DisplayLabel", &"Label")
		theme.set_type_variation(&"TitleLabel", &"Label")
		theme.set_type_variation(&"SubtitleLabel", &"Label")
		theme.set_type_variation(&"MonoLabel", &"Label")
		theme.set_type_variation(&"MonoTight", &"Label")
		theme.set_type_variation(&"FocusPanel", &"PanelContainer")
		theme.set_type_variation(&"MenuRow", &"Button")
