// =====================================================================
//  REGION ANNOTATION (auto-tissue)
// =====================================================================
//  Defines injured vs uninjured tissue regions on a composite time-lapse.
//  The tissue body is auto-thresholded from the anatomy channel (frame 1),
//  the user draws a single midline, and the tissue is cut in two along it.
//  injured = 1, uninjured = 2. The label map is appended as a NEW channel
//  (the last one), replicated across all T frames.
//
//  ORIENTATION STANDARDISATION (first step):
//  Before anything else, the image is normalised to a common orientation
//  so every dataset faces the same way:
//      head   -> LEFT
//      injury -> TOP
//  The user is shown the image and asked which way the head currently
//  points (read from the anatomy channel) and which side the injury is on.
//  The script flips as needed and records what it did in the output name:
//      _FH  = flipped horizontally (head was on the right)
//      _FV  = flipped vertically   (injury was on the bottom)
//  Tags appear in FH-then-FV order, e.g. "..._FH_FV_regions.tif". Because
//  the injury is guaranteed to be on TOP after this step, the region cut
//  always maps top = injured (label 1), bottom = uninjured (label 2).
//
//  EXPECTED CHANNEL LAYOUT (input = output of step 3, mask_microglia):
//    ch1  anatomy marker (mnxbfp)   <- thresholded for the tissue body
//    ch2  microglia marker
//    ch3  neuron trace (dye uptake) <- shown green while drawing the line
//    ch4  microglia mask            <- used later by TrackMate
//    -> this script appends:
//    ch5  regions (injured / uninjured label map)
//
//  The TISSUE_CHANNEL and TRACE_CHANNELS settings below encode that
//  layout; adjust them together if your channel order differs.
// =====================================================================

// ---- CONFIG ---------------------------------------------------------
TRACE_CHANNELS  = "1010";     // active channels while drawing: ch1 + ch3
TRACE_CH_A      = 1;          // first channel shown for tracing (anatomy, magenta)
TRACE_CH_B      = 3;          // second channel shown for tracing (neuron trace, green)
TISSUE_CHANNEL  = 1;          // channel to threshold for the tissue body (anatomy)
BLUR_SIGMA      = 20;         // big Gaussian to merge microglia into one mass
THRESHOLD_METHOD= "Percentile"; // auto-threshold method (loose)
LABEL_INJURED   = 1;
LABEL_UNINJURED = 2;
OUTPUT_SUFFIX   = "_regions";
OVERLAY_COLOR   = "cyan";
OVERLAY_WIDTH   = 2;
// Orientation standardisation targets (what every image is normalised to):
TARGET_HEAD     = "left";     // head should end up pointing this way
TARGET_INJURY   = "top";      // injury should end up on this side
// ---------------------------------------------------------------------

if (nImages == 0) exit("Open a composite first.");
annotateOne(getTitle());

// =====================================================================
function annotateOne(title) {
    selectWindow(title);
    getDimensions(w, h, c, z, t);
    getVoxelSize(vw, vh, vd, vunit);

    // ---- prep view: anatomy (magenta) + neuron trace (green) --------
    // Guard against images that don't have the trace channels (avoids a
    // hard error if run on an unexpected channel layout).
    Stack.setDisplayMode("composite");
    if (c >= TRACE_CH_A) { Stack.setChannel(TRACE_CH_A); run("Magenta"); run("Enhance Contrast", "saturated=0.35"); }
    if (c >= TRACE_CH_B) { Stack.setChannel(TRACE_CH_B); run("Green");   run("Enhance Contrast", "saturated=0.35"); }
    Stack.setActiveChannels(TRACE_CHANNELS);

    // ---- STEP 0: standardise orientation (head left, injury top) ----
    // Ask the user the CURRENT orientation (head read from the anatomy
    // channel), then flip as needed and record what was done in a tag.
    Dialog.create("Standardise orientation");
    Dialog.addMessage("Look at the anatomy channel (ch" + TISSUE_CHANNEL + ").\n" +
                      "Target: head " + TARGET_HEAD + ", injury " + TARGET_INJURY + ".");
    Dialog.addChoice("Head currently points:", newArray("left", "right"), "left");
    Dialog.addChoice("Injury currently on:",   newArray("top", "bottom"), "top");
    Dialog.show();
    curHead   = Dialog.getChoice();
    curInjury = Dialog.getChoice();

    flipTag = "";
    // Horizontal flip if head is on the wrong side.
    if (curHead != TARGET_HEAD) {
        selectWindow(title);
        run("Flip Horizontally", "stack");
        flipTag += "_FH";
        print("Flipped horizontally (head was " + curHead + ").");
    }
    // Vertical flip if injury is on the wrong side.
    if (curInjury != TARGET_INJURY) {
        selectWindow(title);
        run("Flip Vertically", "stack");
        flipTag += "_FV";
        print("Flipped vertically (injury was " + curInjury + ").");
    }
    if (flipTag == "") print("No flip needed — already standard orientation.");

    // After standardisation the injury is guaranteed to be on TARGET_INJURY
    // (top), so the region cut always maps top = injured, bottom = uninjured.
    injurySide = TARGET_INJURY;

    setTool("line");

    // ---- STEP 1: ask ONLY for the midline ---------------------------
    run("Select None");
    waitForUser("Draw the injury boundary",
        "Straight LINE tool: draw the divide across the FULL width,\n" +
        "edge to edge (overshoot slightly), then click OK.");
    if (selectionType() != 5) exit("No straight-line selection found. Use the LINE tool.");
    getSelectionCoordinates(lx, ly);
    x1 = lx[0]; y1 = ly[0]; x2 = lx[1]; y2 = ly[1];
    selectWindow(title); run("Select None");

    // ---- auto-threshold the tissue from ch1, frame 1 ----------------
    selectWindow(title);
    run("Duplicate...", "title=tissue duplicate channels=" + TISSUE_CHANNEL + " frames=1");
    selectWindow("tissue");
    run("8-bit");
    run("Gaussian Blur...", "sigma=" + BLUR_SIGMA);
    setAutoThreshold(THRESHOLD_METHOD + " dark");
    setOption("BlackBackground", true);
    run("Convert to Mask");
    run("Median...", "radius=50");
    run("Options...", "iterations=40 count=1 black do=Dilate");
    run("Keep Largest Region");
    close("tissue");
    selectWindow("tissue-largest");
    rename("tissue");

    // largest-object cleanup: remove small thresholded specks outside the body
    run("Options...", "iterations=1 count=1 black");
    // turn the tissue mask into a selection
    run("Create Selection");
    if (selectionType() == -1) exit("Tissue threshold produced no selection — adjust BLUR_SIGMA / method.");
    roiManager("reset");
    roiManager("add");            // index 0 = tissue body
    close();                      // close the 'tissue' working image

    // ---- build the 'upper half-plane' polygon from the extended line -
    dx = x2 - x1; dy = y2 - y1;
    len = sqrt(dx*dx + dy*dy);
    ux = dx/len; uy = dy/len;
    big = (w + h) * 2;
    ex1 = x1 - ux*big; ey1 = y1 - uy*big;
    ex2 = x2 + ux*big; ey2 = y2 + uy*big;
    hx = newArray(ex1, ex2, ex2, ex1);
    hy = newArray(ey1, ey2, ey2 - big, ey1 - big);
    makeSelection("polygon", hx, hy);
    roiManager("add");            // index 1 = upper half-plane

    // ---- top half = tissue AND half-plane ; bottom = tissue XOR top --
    roiManager("select", newArray(0, 1)); roiManager("AND"); roiManager("add");  // index 2 = TOP
    roiManager("select", newArray(0, 2)); roiManager("XOR"); roiManager("add");  // index 3 = BOTTOM

    if (injurySide == "top") { topValue = LABEL_INJURED;   bottomValue = LABEL_UNINJURED; }
    else                     { topValue = LABEL_UNINJURED; bottomValue = LABEL_INJURED; }

    // ---- build single-plane label, replicate across T ---------------
    newImage("regions_plane", "8-bit black", w, h, 1);
    roiManager("select", 2); setColor(topValue);    fill();
    roiManager("select", 3); setColor(bottomValue); fill();
    run("Select None");

    newImage("regions", "8-bit black", w, h, 1, 1, t);
    for (fr = 1; fr <= t; fr++) {
        selectWindow("regions_plane"); run("Select All"); run("Copy");
        selectWindow("regions"); Stack.setFrame(fr); run("Paste");
    }
    run("Select None");
    selectWindow("regions_plane"); close();

    // ---- fold the region map in as the next channel -----------------
    // GENERALISED: read the original channel count and append 'regions'
    // as channel N+1, so this works regardless of how many channels the
    // input has. (For the standard 4-channel _withMask input this yields
    // a 5-channel output: anatomy, marker, trace, mask, regions.)
    // NOTE: "Merge Channels..." supports up to 7 slots (c1..c7), so the
    // input may have at most 6 channels for 'regions' to fit.
    selectWindow(title);
    run("Select None");
    getDimensions(ow, oh, nCh, oz, ot);
    run("Duplicate...", "title=orig_copy duplicate");

    mergeArgs = "";
    if (nCh > 1) {
        // Split Channels produces "C1-orig_copy", "C2-orig_copy", ...
        run("Split Channels");
        for (ci = 1; ci <= nCh; ci++) {
            mergeArgs += "c" + ci + "=[C" + ci + "-orig_copy] ";
        }
    } else {
        mergeArgs += "c1=[orig_copy] ";
    }
    mergeArgs += "c" + (nCh + 1) + "=[regions] create";

    run("Merge Channels...", mergeArgs);
    // Output name records any flips applied, in FH-then-FV order, before
    // the _regions suffix, e.g. "..._FH_FV_regions".
    finalTitle = title + flipTag + OUTPUT_SUFFIX;
    rename(finalTitle);
    setVoxelSize(vw, vh, vd, vunit);

// ---- overlay: tissue outline + cut line clipped to the tissue --------
selectWindow(finalTitle);
Overlay.remove;

// 1. tissue body outline (ROI index 0)
roiManager("select", 0);
Overlay.addSelection(OVERLAY_COLOR, OVERLAY_WIDTH);

// 2. cut line, clipped to inside the tissue, via a scratch image
newImage("lineclip", "8-bit black", w, h, 1);
makeLine(x1, y1, x2, y2);
run("Line Width...", "line=3");          // a few px so it survives as an area
run("Draw");                             // burn the (overshooting) line in white
run("Select None");
run("Line Width...", "line=1");          // restore default line width

// erase the part of the line OUTSIDE the tissue
roiManager("select", 0);                 // tissue ROI (now applied to lineclip)
run("Make Inverse");
setColor(0); fill();                     // wipe everything outside the tissue
run("Select None");

// recover the surviving in-tissue line segment as a selection
setThreshold(1, 255);
run("Create Selection");
resetThreshold;
nClip = -1;
if (selectionType() != -1) {
    roiManager("add");
    nClip = roiManager("count") - 1;
}
selectWindow("lineclip"); close();

// add the clipped line to the overlay on the final stack
if (nClip != -1) {
    selectWindow(finalTitle);
    roiManager("select", nClip);
    Overlay.addSelection(OVERLAY_COLOR, OVERLAY_WIDTH);
}

selectWindow(finalTitle);
run("Select None");
Overlay.show;
roiManager("reset");

    flipReport = flipTag;
    if (flipReport == "") flipReport = "none";
    print("Built '" + finalTitle + "': flips=" + flipReport +
          ", injured=" + injurySide +
          " -> value " + LABEL_INJURED + ", tissue auto-thresholded (" +
          THRESHOLD_METHOD + ", sigma " + BLUR_SIGMA + "), all " + t + " frames.");
    return finalTitle;
}