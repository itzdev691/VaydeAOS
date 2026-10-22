# Transparent logo asset

`Sources/VaydeAOS/Assets/vayde-mark.png` was edited with the built-in imagegen tool
from the original repository logo. The resulting 1254 × 1254 RGBA PNG is shared
by the app header. The current startup uses a text wordmark instead of this image.
Its four corner pixels have zero alpha.

## Edit prompt

Use case: background-extraction. Edit target: the attached existing VaydeAOS wolf logo PNG, 512 by 512. Remove only the black background and the dark navy ambient haze outside the wolf, replacing them with real alpha transparency. Preserve the wolf emblem exactly: same shape, same blue, red and white flat colors, same detached stripes, eyes, nose, proportions and crisp edges. Preserve all opaque logo interior detail; dark navy features inside the wolf belong to the logo. Do not redesign, redraw, restyle, add outlines, add shadows, add glow, or change the composition. Keep the original 512 by 512 square canvas and original placement/scale of the emblem with transparent surrounding padding. Final output is an actual RGBA transparent PNG, not a checkerboard illustration. Purpose: replace the app's existing logo asset so it blends cleanly over navy UI.
