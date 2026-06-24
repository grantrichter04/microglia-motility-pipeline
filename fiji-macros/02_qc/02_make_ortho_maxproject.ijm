// ============================================================================
//  Orthogonal View Assembler (ImageJ / Fiji macro)
// ----------------------------------------------------------------------------
//  Takes the frontmost hyperstack and builds a single "orthogonal cross"
//  montage: the XY projection (top-left), the YZ projection (top-right) and
//  the XZ projection (bottom), all stitched together with a bright seam line.
//  The original time dimension is preserved so the result can still be played
//  as a movie.
// ============================================================================

// Thickness (in pixels) of the white seam lines drawn between the panels.
borderPx = 3;

// ---- START: frontmost image is the source hyperstack ----
// Grab a handle to the currently active image so we can always return to it,
// regardless of which window becomes active later.
srcID    = getImageID();          // unique numeric ID (stable reference)
srcTitle = getTitle();            // window title (used for naming/printing)

// Read out the physical voxel size (vw/vh/zDepth) and its unit (e.g. microns).
// zDepth is the key value: it's reused to scale the reslices correctly.
getVoxelSize(vw, vh, zDepth, unit);

// Read the pixel/stack dimensions: width, height, channels, Z-slices, frames(t).
getDimensions(width, height, channels, slices, frames);

// Log a summary of the source so the run is traceable in the Log window.
print("Source: " + srcTitle + "  dims=[" + width + "," + height + "," + channels + "," + slices + "," + frames + "]" +
      "  voxel depth=" + zDepth + " " + unit);

// Remember the frame count — Combine later collapses time into Z, so we need
// this to rebuild the hyperstack at the end.
nFrames = frames;

// ---- 1. XY view: Z-project the source (all timepoints) ----
selectImage(srcID);
// Maximum-intensity projection along Z, for every timepoint ("all").
// This is the standard top-down view.
run("Z Project...", "projection=[Max Intensity] all");
rename("XY_view");
run("Fire");                      // apply the "Fire" LUT for nicer contrast
xyWidth  = getWidth();            // record dimensions for later layout maths
xyHeight = getHeight();

// ---- 2. XZ view: reslice from Top (to scale), project, Fire ----
selectImage(srcID);
// Reslice from the Top edge to produce an XZ cross-section stack.
// output=zDepth keeps the new slices physically to scale (isotropic spacing).
run("Reslice [/]...", "output=" + zDepth + " start=Top");
xzStackID = getImageID();         // keep the resliced stack's ID to close it later
// Collapse the resliced stack into a single XZ projection.
run("Z Project...", "projection=[Max Intensity] all");
rename("XZ_view");
xzHeight = getHeight();           // record height for the padding/layout step
selectImage(xzStackID);           // go back to the intermediate reslice stack...
close();                          // ...and close it to keep things tidy
selectWindow("XZ_view");
run("Fire");

// ---- 3. YZ view: reslice from Left with rotate, project, Fire ----
selectImage(srcID);
// Reslice from the Left edge (rotated) to produce a YZ cross-section stack.
run("Reslice [/]...", "output=" + zDepth + " start=Left rotate");
yzStackID = getImageID();
// Collapse it into a single YZ projection.
run("Z Project...", "projection=[Max Intensity] all");
rename("YZ_view");
yzWidth = getWidth();             // record width for the layout maths
selectImage(yzStackID);           // close the intermediate reslice stack
close();
selectWindow("YZ_view");
run("Fire");

// ---- 4. Pad XZ on the right to match XY+YZ width ----
// The bottom row (XZ) must span the full width of the top row (XY + YZ),
// otherwise the vertical Combine in step 6 will fail.
rowWidth = xyWidth + yzWidth;
selectWindow("XZ_view");
// Grow the canvas to the full row width, anchoring the image on the left
// ("Center-Left") and filling the new area with zeros (black).
run("Canvas Size...", "width=" + rowWidth + " height=" + xzHeight +
    " position=Center-Left zero");
print("Padded XZ to width " + rowWidth);

// ---- 5. Combine XY + YZ horizontally ----
// Stitch the two top panels side by side into a single "TOPROW" stack.
run("Combine...", "stack1=[XY_view] stack2=[YZ_view]");
rename("TOPROW");

// ---- 6. Combine top row + padded XZ vertically ----
// The "combine" keyword here tells Combine to stack vertically instead of
// horizontally, placing XZ underneath the top row.
run("Combine...", "stack1=[TOPROW] stack2=[XZ_view] combine");
rename("Orthogonal_" + srcTitle);
getDimensions(ow, oh, oc, os, of);
print("Final dims: [" + ow + "," + oh + "," + oc + "," + os + "," + of + "]");

// ---- 6b. Restore the time dimension (Combine flattened it to Z-slices) ----
// Combine treats every timepoint as a Z-slice, so we re-interpret the stack as
// 1 channel x 1 Z x nFrames timepoints to get a playable movie back.
run("Stack to Hyperstack...",
    "order=xyctz channels=1 slices=1 frames=" + nFrames + " display=Grayscale");
print("Re-stamped as 1c x 1z x " + nFrames + "t");

// ---- 7. Bright border lines at the seams ----
// Draw white lines along the panel boundaries so the three views are visually
// separated in the final montage.
setForegroundColor(255, 255, 255);
seamX = xyWidth;                  // vertical seam sits at the XY/YZ boundary
seamY = xyHeight;                 // horizontal seam sits at the top-row/XZ boundary
half  = floor(borderPx / 2);      // centre the line on the seam

// Vertical seam: full-height rectangle, filled across every slice ("stack").
makeRectangle(seamX - half, 0, borderPx, xyHeight);
run("Fill", "stack");

// Horizontal seam: full-width rectangle across the whole image.
makeRectangle(0, seamY - half, getWidth(), borderPx);
run("Fill", "stack");

run("Select None");               // clear the selection so nothing stays highlighted
updateDisplay();                  // refresh the viewer to show the filled seams
print("Done — orthogonal cross assembled, " + borderPx + "px borders.");