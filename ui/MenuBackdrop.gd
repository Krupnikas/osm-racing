# MenuBackdrop.gd — atmospheric backdrop wrapper.
# The texture already bakes the full atmosphere (glows, grid, horizon
# streaks, faint wordmark). This scene only wraps it as a Control so it
# can be instanced into menu screens with `mouse_filter=IGNORE`.
extends Control
