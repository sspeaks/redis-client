### 2026-09-05: Bound command frames before vector conversion
**By:** Lead
**What:** Command routing counts at most 65,537 frame cells before validation and constructs a vector only when the frame is within the 65,536-element limit. A final optional repeated argument uses the terminal parser, retaining only complete results.
**Why:** Full-list length and conversion can consume unbounded input, while prefix-state retention can discard the valid terminal parse at the 4,096-state limit. Bounded counting uses O(1) auxiliary space; accepted frame storage is O(n) up to the fixed cap.
