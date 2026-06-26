// ============================================================================
//  Orthogonal View Assembler — DUAL (side-by-side) version
// ----------------------------------------------------------------------------
//  Builds an orthogonal "cross" montage (XY / YZ / XZ) for TWO user-chosen
//  hyperstacks, then places the two montages side by side into one stack.
// ============================================================================

// Thickness (in pixels) of the white seam lines drawn between the panels.
borderPx = 3;

// ---- Ask the user which open images go on the left and the right ----
titles = getList("image.titles");
if (titles.length < 2)
    exit("You need at least two images open to combine side by side.");

Dialog.create("Select images to combine");
Dialog.addChoice("Left image:",  titles, titles[0]);
Dialog.addChoice("Right image:", titles, titles[1]);
Dialog.show();
leftTitle  = Dialog.getChoice();
rightTitle = Dialog.getChoice();

if (leftTitle == rightTitle)
    exit("Please choose two different images for left and right.");

// ---- Build the orthogonal montage for each chosen image ----
selectWindow(leftTitle);
leftResult  = buildOrthogonal(getImageID(), borderPx);

selectWindow(rightTitle);
rightResult = buildOrthogonal(getImageID(), borderPx);

// ---- Combine the two montages horizontally (left | right) ----
run("Combine...", "stack1=[" + leftResult + "] stack2=[" + rightResult + "]");
rename("Orthogonal_combined");
print("Done — combined '" + leftResult + "' (left) with '" + rightResult + "' (right).");


// ============================================================================
//  FUNCTION: build the orthogonal cross montage from one source image.
//  Returns the title of the resulting montage window.
// ============================================================================
function buildOrthogonal(srcID, borderPx) {

    // ---- START: source hyperstack ----
    selectImage(srcID);
    srcTitle = getTitle();            // window title (used for naming/printing)

    // Read out the physical voxel size and unit.
    getVoxelSize(vw, vh, zDepth, unit);
    // Read the pixel/stack dimensions.
    getDimensions(width, height, channels, slices, frames);
    print("Source: " + srcTitle + "  dims=[" + width + "," + height + "," +
          channels + "," + slices + "," + frames + "]" +
          "  voxel depth=" + zDepth + " " + unit);

    // Remember the frame count — Combine later collapses time into Z.
    nFrames = frames;

    // ---- 1. XY view: Z-project the source (all timepoints) ----
    selectImage(srcID);
    run("Z Project...", "projection=[Max Intensity] all");
    rename("XY_view_" + srcTitle);
    xyWidth  = getWidth();
    xyHeight = getHeight();

    // ---- 2. XZ view: reslice from Top (to scale), project ----
    selectImage(srcID);
    run("Reslice [/]...", "output=" + zDepth + " start=Top");
    xzStackID = getImageID();
    run("Z Project...", "projection=[Max Intensity] all");
    rename("XZ_view_" + srcTitle);
    xzHeight = getHeight();
    selectImage(xzStackID);
    close();
    selectWindow("XZ_view_" + srcTitle);

    // ---- 3. YZ view: reslice from Left with rotate, project ----
    selectImage(srcID);
    run("Reslice [/]...", "output=" + zDepth + " start=Left rotate");
    yzStackID = getImageID();
    run("Z Project...", "projection=[Max Intensity] all");
    rename("YZ_view_" + srcTitle);
    yzWidth = getWidth();
    selectImage(yzStackID);
    close();
    selectWindow("YZ_view_" + srcTitle);

    // ---- 4. Pad XZ on the right to match XY+YZ width ----
    rowWidth = xyWidth + yzWidth;
    selectWindow("XZ_view_" + srcTitle);
    run("Canvas Size...", "width=" + rowWidth + " height=" + xzHeight +
        " position=Center-Left zero");
    print("Padded XZ to width " + rowWidth);

    // ---- 5. Combine XY + YZ horizontally ----
    run("Combine...", "stack1=[XY_view_" + srcTitle +
        "] stack2=[YZ_view_" + srcTitle + "]");
    rename("TOPROW_" + srcTitle);

    // ---- 6. Combine top row + padded XZ vertically ----
    run("Combine...", "stack1=[TOPROW_" + srcTitle +
        "] stack2=[XZ_view_" + srcTitle + "] combine");
    outTitle = "Orthogonal_" + srcTitle;
    rename(outTitle);
    getDimensions(ow, oh, oc, os, of);
    print("Final dims: [" + ow + "," + oh + "," + oc + "," + os + "," + of + "]");

    // ---- 6b. Restore the time dimension ----
    run("Stack to Hyperstack...",
        "order=xyctz channels=1 slices=1 frames=" + nFrames +
        " display=Grayscale");
    print("Re-stamped as 1c x 1z x " + nFrames + "t");

    // ---- 7. Bright border lines at the seams ----
    setForegroundColor(255, 255, 255);
    seamX = xyWidth;
    seamY = xyHeight;
    half  = floor(borderPx / 2);
    makeRectangle(seamX - half, 0, borderPx, xyHeight);
    run("Fill", "stack");
    makeRectangle(0, seamY - half, getWidth(), borderPx);
    run("Fill", "stack");
    run("Select None");
    updateDisplay();
    print("Done — orthogonal cross assembled for " + srcTitle +
          ", " + borderPx + "px borders.");

    return outTitle;
}