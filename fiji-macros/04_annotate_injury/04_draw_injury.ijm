// =====================================================================
//  REGION ANNOTATION (auto-tissue)  —  single / batch
// =====================================================================
//  Defines injured vs uninjured tissue regions on a composite time-lapse.
//  The tissue body is auto-thresholded from the anatomy channel (frame 1),
//  the user draws a single midline, and the tissue is cut in two along it.
//  Labels follow a spatial gradient so that median/mean of boundary spots
//  degrades to an ADJACENT region: uninjured = 1, injured = 2, core = 3
//  (0 = outside tissue). The label map is appended as a NEW channel
//  (the last one), replicated across all T frames.
//
//  MODES
//  -----
//  Single : run on the currently open image (same as before).
//  Batch  : pick a directory; every *_MIP.tif is processed in turn.
//           The regions channel is appended in place — the original file
//           is overwritten with one extra channel added (non-destructive;
//           strip the last channel any time to recover the original data).
//           Any orientation flips are baked into the pixel data; the flip
//           tags (_FH / _FV) appear only in the Fiji window title for
//           visual feedback, not in the saved filename.
//           NOTE: ImageJ macros have no try/catch — any exit() inside
//           annotateOne() (e.g. no line drawn) will halt the whole batch.
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
//  always maps top = injured (label 2), bottom = uninjured (label 1).
//
//  EXPECTED CHANNEL LAYOUT (input = output of step 3, mask_microglia):
//    ch1  anatomy marker (mnxbfp)   <- thresholded for the tissue body
//    ch2  microglia marker
//    ch3  neuron trace (dye uptake) <- shown green while drawing the line
//    ch4  microglia mask            <- used later by TrackMate
//    -> this script appends:
//    ch5  regions label map (spatial gradient): 0 = outside tissue,
//         1 = uninjured, 2 = injured (penumbra), 3 = injury core
//         (optional tight ROI; overrides injured (2) inside it)
//
//  The TISSUE_CHANNEL and TRACE_CHANNELS settings below encode that
//  layout; adjust them together if your channel order differs.
// =====================================================================

// ---- CONFIG ---------------------------------------------------------
TRACE_CHANNELS  = "1010";     // active channels while drawing: ch1 + ch3
TRACE_CH_A      = 1;          // first channel shown for tracing (anatomy, magenta)
TRACE_CH_B      = 3;          // second channel shown for tracing (neuron trace, green)
TISSUE_CHANNEL  = 1;          // channel to threshold for the tissue body (anatomy)
BLUR_SIGMA      = 10;         // big Gaussian to merge microglia into one mass
THRESHOLD_METHOD= "Percentile"; // auto-threshold method (loose)
// Region labels follow a spatial gradient (uninjured -> injured -> core) so
// that the median/mean intensity of a boundary-straddling spot resolves to an
// ADJACENT region rather than jumping across (e.g. avoids core+penumbra -> uninjured).
LABEL_UNINJURED = 1;
LABEL_INJURED   = 2;
// ---- injury-core sub-region (optional) ----
DRAW_CORE          = true;     // prompt to draw a tight injury-core ROI?
                               // false = skip it, output stays 0/1/2 (back-compatible).
LABEL_CORE         = 3;        // value written for the core; OVERRIDES injured (2) inside the ROI.
CORE_DRAW_CHANNELS = "0010";   // channels shown while drawing the core: ch2 (microglia) + ch3 (trace)
CORE_OVERLAY_COLOR = "yellow"; // QC overlay colour for the core outline
OUTPUT_SUFFIX   = "_regions";  // appended to Fiji window title only — NOT the saved filename
OVERLAY_COLOR   = "cyan";
OVERLAY_WIDTH   = 2;
// Orientation standardisation targets (what every image is normalised to):
TARGET_HEAD     = "left";     // head should end up pointing this way
TARGET_INJURY   = "top";      // injury should end up on this side
// ---------------------------------------------------------------------

// ---- LAUNCH: choose mode -------------------------------------------
Dialog.create("Region Annotation — Mode");
Dialog.addMessage("Stage 4: annotate injury region.");
Dialog.addChoice("Mode", newArray("Single open image", "Batch directory"), "Single open image");
Dialog.show();
runMode = Dialog.getChoice();

if (runMode == "Single open image") {
    if (nImages == 0) exit("No image is open. Open a *_MIP.tif composite first.");
    sdir = getDirectory("image");      // "" if never saved to disk
    annotateOne(getTitle(), sdir);
}

 else {
    // ---- BATCH: loop over every *_MIP.tif in a chosen directory --------
    inputDir = getDirectory("Select root directory to search for *_MIP.tif files");
    if (inputDir == "") exit("No directory selected.");

    // Recursively collect all *_MIP.tif paths under inputDir (including subdirs).
    var targets = newArray(0);
    collectMIPs(inputDir);
    Array.sort(targets);

    n = targets.length;
    if (n == 0) exit("No *_MIP.tif files found under:\n" + inputDir);

    print("\\Clear");
    getDateAndTime(yr, mo, dow, dy, hr, mn, sc, ms);
    print("=== Region Annotation Batch  " + yr + "-" +
          IJ.pad(mo+1, 2) + "-" + IJ.pad(dy, 2) + "  " +
          IJ.pad(hr, 2)   + ":" + IJ.pad(mn, 2) + ":" + IJ.pad(sc, 2) + " ===");
    print("Directory : " + inputDir);
    print("Files     : " + n);
    print("(Each file requires interactive input — orientation dialog + line draw.)");
    print("");

    nOK = 0;

    for (i = 0; i < n; i++) {
        filePath = targets[i];                   // full absolute path from collectMIPs
        fname    = File.getName(filePath);        // just the filename for logging
        print("[" + (i+1) + "/" + n + "]  Opening: " + fname);
        print("    Path: " + filePath);

        open(filePath);
        result = annotateOne(getTitle());   // interactive; exits batch on any error

        // Overwrite original in place — regions channel is appended additively.
        selectWindow(result);
        saveAs("Tiff", filePath);
        close();

        nOK++;
        print("    -> Amended in place: " + fname);
        print("");
    }

    getDateAndTime(yr, mo, dow, dy, hr, mn, sc, ms);
    print("=== DONE  " + IJ.pad(hr, 2) + ":" + IJ.pad(mn, 2) + ":" + IJ.pad(sc, 2) +
          "  —  " + nOK + "/" + n + " annotated ===");
}

// =====================================================================
// Recursive *_MIP.tif collector — appends full paths to the global
// var targets array. Called with the root inputDir; recurses into any
// subdirectory it finds (getFileList marks dirs with a trailing slash).
function collectMIPs(dir) {
    list = getFileList(dir);
    for (i = 0; i < list.length; i++) {
        if (endsWith(list[i], "/"))
            collectMIPs(dir + list[i]);        // descend into subdirectory
        else if (endsWith(list[i], "_MIP.tif"))
            targets = Array.concat(targets, dir + list[i]);
    }
}

// =====================================================================
function annotateOne(title, outDir) {
    selectWindow(title);
    getDimensions(w, h, c, z, t);
    getVoxelSize(vw, vh, vd, vunit);

    // Strip .tif extension so output naming doesn't embed it mid-filename
    // (Fiji window titles include the extension when opened from disk).
    baseName = title;
    if (endsWith(toLowerCase(baseName), ".tif"))
        baseName = substring(baseName, 0, lengthOf(baseName) - 4);

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

    setTool("polyline");

    // ---- STEP 1: draw the injury boundary (segmented line) ----------
    // Show only the neuron trace channel (ch3, green) while drawing —
    // the axon path makes the injury boundary easiest to judge.
    // Keep re-prompting until a segmented-line selection (type 6) is
    // active; showMessage explains the problem if OK is clicked too early.
    Stack.setActiveChannels("0010");  // ch3 only (neuron trace, green)
    run("Select None");
    gotLine = false;
    while (!gotLine) {
        waitForUser("Draw the injury boundary",
            "SEGMENTED LINE tool: click to place vertices along the boundary,\n" +
            "double-click to finish. Draw edge to edge (overshoot slightly).\n" +
            "(Only ch" + TRACE_CH_B + " — neuron trace — is shown for clarity.)");
        gotLine = (selectionType() == 5 || selectionType() == 6);
        if (!gotLine)
            showMessage("No line detected",
                "No line selection is active.\n \n" +
                "Use the SEGMENTED LINE tool: click to place vertices,\n" +
                "double-click to finish, then click OK in the next prompt.");
    }
    getSelectionCoordinates(lx, ly);
    nPts = lx.length;
    selectWindow(title); run("Select None");

    // ---- STEP 1b: draw the injury-core ROI (optional) ---------------
    // A tight closed region enclosing the cluster of injured cells. It is
    // stored as label LABEL_CORE and later OVERRIDES injured wherever it
    // sits, so the result is a core-vs-penumbra-vs-uninjured gradient.
    // Drawn on the microglia + trace channels so the cluster is visible.
    // coreN stays 0 if DRAW_CORE is off -> downstream core steps are skipped.
    coreN = 0;
    if (DRAW_CORE) {
        Stack.setActiveChannels(CORE_DRAW_CHANNELS);
        setTool("polygon");
        run("Select None");
        gotCore = false;
        while (!gotCore) {
            waitForUser("Draw the injury-core ROI",
                "POLYGON (or FREEHAND) tool: enclose the tight cluster of\n" +
                "injured cells, double-click to close. Becomes region " + LABEL_CORE + ".\n" +
                "(Showing microglia + neuron-trace channels.)");
            st = selectionType();
            // accept any AREA selection: rectangle/oval/polygon/freehand/traced
            gotCore = (st == 0 || st == 1 || st == 2 || st == 3 || st == 4);
            if (!gotCore)
                showMessage("No area selection",
                    "Use the POLYGON or FREEHAND tool to enclose the core,\n" +
                    "double-click to close, then click OK.");
        }
        getSelectionCoordinates(cx, cy);
        coreN = cx.length;
        selectWindow(title); run("Select None");
    }

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
    run("Options...", "iterations=5 count=1 black do=Dilate");
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

    // ---- build the 'upper' polygon from the extended polyline ----------
    // Extend a ray backwards from the first vertex (along the first segment)
    // and forwards from the last vertex (along the last segment), then close
    // the polygon by looping way above the image — capturing everything on
    // the injured side of the boundary. Works for any number of vertices;
    // a 2-point line is just a degenerate case of the same geometry.
    big = (w + h) * 2;
    dx0 = lx[1] - lx[0];         dy0 = ly[1] - ly[0];
    len0 = sqrt(dx0*dx0 + dy0*dy0);
    ex_s = lx[0] - (dx0/len0)*big;  ey_s = ly[0] - (dy0/len0)*big;

    dxE = lx[nPts-1] - lx[nPts-2];  dyE = ly[nPts-1] - ly[nPts-2];
    lenE = sqrt(dxE*dxE + dyE*dyE);
    ex_e = lx[nPts-1] + (dxE/lenE)*big;  ey_e = ly[nPts-1] + (dyE/lenE)*big;

    // Polygon: extended-start → all vertices → extended-end → two top-of-image corners
    nPoly = nPts + 4;
    hx = newArray(nPoly);  hy = newArray(nPoly);
    hx[0] = ex_s;  hy[0] = ey_s;
    for (k = 0; k < nPts; k++) { hx[k+1] = lx[k];  hy[k+1] = ly[k]; }
    hx[nPts+1] = ex_e;        hy[nPts+1] = ey_e;
    hx[nPts+2] = ex_e;        hy[nPts+2] = ey_e - big;
    hx[nPts+3] = ex_s;        hy[nPts+3] = ey_s - big;
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

    // core LAST so it overrides injured/uninjured inside its ROI,
    // clipped to the tissue body (index 0) so it can't spill into background.
    coreClipIdx = -1;
    if (DRAW_CORE && coreN > 0) {
        makeSelection("polygon", cx, cy);
        roiManager("add");                                   // core (raw)
        coreRawIdx = roiManager("count") - 1;
        roiManager("select", newArray(0, coreRawIdx));
        roiManager("AND"); roiManager("add");                // core AND tissue
        coreClipIdx = roiManager("count") - 1;
        roiManager("select", coreClipIdx);
        setColor(LABEL_CORE); fill();
    }
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
    // Window title: base name + flip tags + _regions suffix for visual feedback.
    // The SAVED FILE is always the original path — see the batch loop above.
    finalTitle = baseName + flipTag + OUTPUT_SUFFIX;
    rename(finalTitle);
    setVoxelSize(vw, vh, vd, vunit);

    // Close the original — Merge Channels consumed orig_copy but left the
    // source image open. Close it now so batch mode doesn't accumulate windows.
    if (isOpen(title)) { selectWindow(title); close(); }
    selectWindow(finalTitle);

// ---- overlay: tissue outline + cut line clipped to the tissue --------
selectWindow(finalTitle);
Overlay.remove;

// 1. tissue body outline (ROI index 0)
roiManager("select", 0);
Overlay.addSelection(OVERLAY_COLOR, OVERLAY_WIDTH);

// 2. cut line, clipped to inside the tissue, via a scratch image
newImage("lineclip", "8-bit black", w, h, 1);
makeSelection("polyline", lx, ly);
run("Line Width...", "line=3");          // a few px so it survives as an area
run("Draw");                             // burn the boundary line in white
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

// add the injury-core outline (tissue-clipped) to the overlay
if (DRAW_CORE && coreClipIdx != -1) {
    selectWindow(finalTitle);
    roiManager("select", coreClipIdx);
    Overlay.addSelection(CORE_OVERLAY_COLOR, OVERLAY_WIDTH);
}

selectWindow(finalTitle);
run("Select None");
Overlay.show;

    // ---- save QC ROIs as a .zip sidecar -----------------------------
    // Keep only the meaningful ROIs (tissue, clipped cut line, clipped core),
    // not the half-plane / boolean temporaries. We re-add them to a clean
    // manager with sensible names, then save.
    // Grab the geometry we want BEFORE reset by re-selecting from the
    // current manager and renaming.
    roiManager("select", 0);
    roiManager("rename", "tissue_body");
    if (nClip != -1) {
        roiManager("select", nClip);
        roiManager("rename", "cut_line");
    }
    if (DRAW_CORE && coreClipIdx != -1) {
        roiManager("select", coreClipIdx);
        roiManager("rename", "injury_core");
    }

    if (outDir != "") {
        // Build an index list of just the keepers, deselect-save the lot.
        // Easiest robust path: select the keepers, but roiManager("save")
        // saves ALL ROIs in the manager — so instead remove the temporaries.
        // Indices to drop: everything except 0, nClip, coreClipIdx.
        keep = newArray(0);
        keep = Array.concat(keep, 0);
        if (nClip != -1)                          keep = Array.concat(keep, nClip);
        if (DRAW_CORE && coreClipIdx != -1)       keep = Array.concat(keep, coreClipIdx);

        total = roiManager("count");
        drop  = newArray(0);
        for (q = 0; q < total; q++) {
            isKeeper = false;
            for (kk = 0; kk < keep.length; kk++) if (keep[kk] == q) isKeeper = true;
            if (!isKeeper) drop = Array.concat(drop, q);
        }
        if (drop.length > 0) { roiManager("select", drop); roiManager("delete"); }

        roiManager("deselect");
        roiPath = outDir + baseName + flipTag + "_ROIs.zip";
        roiManager("save", roiPath);
        print("    ROI set saved: " + roiPath);
    }
    // -----------------------------------------------------------------

    

roiManager("reset");

    flipReport = flipTag;
    if (flipReport == "") flipReport = "none";
    print("Built '" + finalTitle + "': flips=" + flipReport +
          ", injured=" + injurySide +
          " -> value " + LABEL_INJURED + ", tissue auto-thresholded (" +
          THRESHOLD_METHOD + ", sigma " + BLUR_SIGMA + "), all " + t + " frames.");
    if (DRAW_CORE && coreN > 0)
        print("  + injury-core ROI -> value " + LABEL_CORE +
              " (overrides injured inside it).");
    else if (DRAW_CORE)
        print("  (injury-core enabled but none drawn — output is 0/1/2 only).");
    return finalTitle;
}