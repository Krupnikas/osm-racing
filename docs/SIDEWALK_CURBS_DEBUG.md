# Sidewalk/Road Intersection Debug

## Problem
Footway way 694466375 visually crosses road way 45727262 diagonally, which doesn't match reality.

## Debug Data Collected

### Footway 694466375 (тротуар)
- Original: 4 points
- Smoothed: 21 points (Catmull-Rom spline)
- Width: 4.0m (±2m from centerline)
- Path: Diagonal from (-500.8, 192.9) to (-530.4, 338.5)

Key smoothed points in intersection zone:
```
(-514.3644, 259.2627) - point 6
(-516.2451, 268.516)  - point 7
(-518.0145, 277.239)  - point 8
(-519.6783, 285.4532) - point 9
(-521.2421, 293.1802) - point 10
```

### Road 45727262 (Остинская улица)
- Original: 19 points
- Smoothed: 90 points (Catmull-Rom spline)
- Width: 8.0m (±4m from centerline)

Key smoothed points in intersection zone:
```
(-509.7311, 271.5171) - point 6 (original was nearby)
(-511.6534, 283.9125) - point 7
(-513.5111, 296.7268) - point 8
```

## Analysis

The footway path is **diagonal** - it moves in both X and Y:
- From X=-500 to X=-530 (moving left/west)
- From Y=192 to Y=338 (moving down/south)

The road also curves through this area. 

**Potential Issue**: Catmull-Rom smoothing adds many interpolated points between the original 4 points. This creates smooth curves, but the curves might be crossing the road path when they shouldn't.

## Next Steps

Need to check:
1. Are the original OSM points correct? (Check OpenStreetMap data)
2. Is smoothing creating false intersections?
3. Should we disable smoothing for footways?
4. Should we reduce smoothing aggressiveness?

## OSM Data to Verify
- Way 694466375: https://www.openstreetmap.org/way/694466375
- Way 45727262: https://www.openstreetmap.org/way/45727262
