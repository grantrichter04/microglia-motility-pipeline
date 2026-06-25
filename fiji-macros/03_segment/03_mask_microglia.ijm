// =====================================================================
//  STAGE 3 — MICROGLIA SEGMENTATION + MASK CLEANUP
//  Microglia Motility Pipeline  |  Richter Lab, Macquarie University
// =====================================================================
//
//  Adds a cleaned binary microglia mask as an extra channel directly
//  to each input image. The original window is updated in place —
//  no separate "_withMask" window is created.
//
//  Channel layout after this stage:
//    ch1  Anatomy / all neurons (mnx:BFP)       — unchanged
//    ch2  Microglia fluorescence                 — unchanged  ← classifier trained here
//    ch3  Injured neurons (dye uptake)           — unchanged
//    ch4  Binary microglia mask (NEW)            ← added by this script
//
//  Two run modes (selected at launch):
//    Active image — runs on the currently open image.
//    Batch        — walks every subdirectory under a chosen parent
//                   folder, finds each "*_MIP.tif", processes it, saves
//                   the result as "<name>_withMask.tif" in the same
//                   directory, then closes before the next file.
//
//  Per-image pipeline:
//    1. Duplicate the marker channel into a working copy.
//    2. Ensure time lives in FRAMES (not slices) — required by Labkit.
//    3. Run the Labkit pixel classifier on the working copy.
//    4. Clean the mask: binarise → per-frame Area Opening → median filter.
//    5. Merge the cleaned mask into the original as a new channel (in place).
//    6. Close all intermediate windows.
//
//  Requirements: Fiji with the Labkit and MorphoLibJ plugins installed.
//
// =====================================================================


// ---- CONFIG ---------------------------------------------------------

var DEFAULT_CLASSIFIER = "";   // Pre-fills the dialog path field.
                               // Leave empty to always prompt with a browser,
                               // or paste your path here (Windows: use double
                               // backslashes, e.g. "C:\\models\\microglia.classifier").

var CHANNEL_TO_KEEP = 2;       // Channel index the Labkit classifier was trained on
                               // (1-based; ch2 = microglia fluorescence).
var MIN_AREA        = 800;     // Minimum foreground object area to keep (pixels²).
                               // Objects smaller than this are removed as noise.
var MEDIAN_RADIUS   = 2;       // Radius (pixels) of the final median smoothing pass.
                               // Smooths jagged mask edges without shrinking objects.

var MIP_SUFFIX = "_MIP.tif";   // Batch mode: only process files whose name ends with this.
                               // Comparison is case-insensitive.


// ---- LAUNCH DIALOG --------------------------------------------------
//  One dialog collects both the run mode and the classifier path.
//  If DEFAULT_CLASSIFIER is empty, the Browse checkbox auto-ticks.

browseByDefault = (lengthOf(DEFAULT_CLASSIFIER) == 0);

Dialog.create("Stage 3 — Microglia Segmentation");
Dialog.addMessage("Labkit segmentation + binary mask cleanup");
Dialog.addRadioButtonGroup("Run mode:",
    newArray("Active open image", "Batch folder (subdirs, *_MIP.tif)"),
    2, 1, "Active open image");
Dialog.addString("Classifier path:", DEFAULT_CLASSIFIER, 60);
Dialog.addCheckbox("Browse for classifier file", browseByDefault);
Dialog.show();

mode           = Dialog.getRadioButton();
classifierPath = Dialog.getString();
doBrowse       = Dialog.getCheckbox();

if (doBrowse || lengthOf(classifierPath) == 0) {
    picked = File.openDialog("Select your .classifier file");
    if (picked != "") classifierPath = picked;
}
if (lengthOf(classifierPath) == 0 || !File.exists(classifierPath))
    exit("Classifier not found:\n" + classifierPath);

print("Classifier: " + classifierPath);

// ---- DISPATCH -------------------------------------------------------
if (startsWith(mode, "Batch")) {
    parentDir = getDirectory("Choose the PARENT folder (contains the subdirectories)");
    if (parentDir == "") exit("No folder chosen.");
    runBatch(parentDir, classifierPath);
} else {
    if (nImages == 0) exit("No image is open — please open a time-lapse first.");
    imgTitle = getTitle();
    processOne(imgTitle, classifierPath);
    print("Pipeline complete — mask added as new channel to '" + imgTitle + "'");
}


// =====================================================================
//  BATCH DRIVER
//
//  Finds every "*_MIP.tif" file in subdirectories under parentDir,
//  processes each one with processOne(), saves the result as
//  "<name>_withMask.tif" in the same directory as the source, and
//  closes all windows before moving to the next file.
//
//  Runs ON SCREEN (not in headless/batch mode) so Labkit and window
//  references behave consistently across files.
// =====================================================================
function runBatch(parentDir, classifierPath) {
    mipFiles = findMipFiles(parentDir);

    if (mipFiles.length == 0) {
        print("No '" + MIP_SUFFIX + "' files found under: " + parentDir);
        exit("No '" + MIP_SUFFIX + "' files found under: " + parentDir);
    }
    print("Batch: " + mipFiles.length + " file(s) to process.");

    for (i = 0; i < mipFiles.length; i++) {
        path = mipFiles[i];
        print("\n===== [" + (i+1) + "/" + mipFiles.length + "] " + path + " =====");

        open(path);
        originalTitle = getTitle();   // Capture the displayed title (may differ from filename)

        processOne(originalTitle, classifierPath);

        // After processOne the window still carries originalTitle but now has
        // the mask as an extra channel. Overwrite the source file in place.
        if (isOpen(originalTitle)) {
            selectWindow(originalTitle);
            saveAs("Tiff", path);
            print("Saved (overwritten): " + path);
        } else {
            print("WARNING: expected window '" + originalTitle + "' not found — nothing saved.");
        }

        closeAllImages();   // Clear all windows before opening the next file
    }
    print("\nBatch complete.");
}

// ---- Helper: find all MIP files one level deep under parentDir ------
//
//  Expected layout:  parentDir / experiment_subdir / *_MIP.tif
//
//  IMPORTANT — no recursion here. ImageJ macro variables are ALL GLOBAL
//  (there are no true local variables inside functions). A recursive call
//  would overwrite the outer call's loop variables (i, list, full, etc.),
//  corrupting the search and producing paths like "0". A flat two-level
//  loop with distinct variable names (j / k, topList / subList) is safe.
function findMipFiles(parentDir) {
    results = newArray(0);
    topList = getFileList(parentDir);

    for (j = 0; j < topList.length; j++) {
        // Skip files at the top level — MIP files live inside subdirectories.
        // Fiji always returns subdirectory entries with a trailing "/".
        if (!endsWith(topList[j], "/")) continue;

        subDir  = parentDir + topList[j];
        subList = getFileList(subDir);

        for (k = 0; k < subList.length; k++) {
            if (endsWith(toLowerCase(subList[k]), toLowerCase(MIP_SUFFIX))) {
                results = Array.concat(results, subDir + subList[k]);
            }
        }
    }
    return results;
}

// ---- Helper: close every open image window --------------------------
function closeAllImages() {
    while (nImages > 0) {
        selectImage(nImages);
        close();
    }
}


// =====================================================================
//  PER-IMAGE PIPELINE
//  Orchestrates the six processing steps for one time-lapse image.
// =====================================================================
function processOne(originalTitle, classifierPath) {
    selectWindow(originalTitle);
    workTitle  = extractChannel(originalTitle, CHANNEL_TO_KEEP); // Step 1
    prepForLabkit(workTitle);                                     // Step 2
    segTitle   = segmentWithLabkit(workTitle, classifierPath);    // Step 3
    cleanTitle = cleanMask(segTitle);                             // Step 4
    addMaskAsChannel(originalTitle, cleanTitle);                  // Step 5
    cleanupWindows(originalTitle);                                // Step 6
}


// =====================================================================
//  STEP 1 — EXTRACT MARKER CHANNEL
//
//  Duplicates the classifier's training channel into a separate window.
//  Labkit will run on this copy; the original multi-channel image is
//  left untouched at this stage.
// =====================================================================
function extractChannel(srcTitle, channel) {
    selectWindow(srcTitle);
    workTitle = "work_ch" + channel;
    run("Duplicate...", "title=" + workTitle + " duplicate channels=" + channel);
    print("  Step 1: extracted ch" + channel + " from '" + srcTitle +
          "' → '" + workTitle + "'");
    return workTitle;
}


// =====================================================================
//  STEP 2 — FIX TIME DIMENSION FOR LABKIT
//
//  Labkit expects 2D + time, with time stored in the FRAMES dimension,
//  not SLICES. Orthogonal projections often arrive with timepoints
//  stored as slices; this step re-declares the stack dimensions if so.
// =====================================================================
function prepForLabkit(workTitle) {
    selectWindow(workTitle);
    getDimensions(w, h, c, z, t);
    if (z > 1 && t == 1) {
        run("Properties...", "channels=1 slices=1 frames=" + (z * t));
        print("  Step 2: reassigned " + (z * t) + " slices → frames");
    } else {
        print("  Step 2: dimensions OK (z=" + z + ", t=" + t + ") — no change needed");
    }
}


// =====================================================================
//  STEP 3 — LABKIT SEGMENTATION
//
//  Runs the trained pixel classifier on the marker channel copy.
//  Labkit requires a visible (non-headless) active image, so batch
//  mode is temporarily disabled if it was active, then restored after.
//  GPU acceleration is off by default — set use_gpu=true below if a
//  CUDA-capable GPU is available and the Labkit GPU extension is installed.
// =====================================================================
function segmentWithLabkit(inputTitle, classifierPath) {
    selectWindow(inputTitle);

    // Temporarily disable batch mode: Labkit needs a displayed window
    wasBatch = is("Batch Mode");
    if (wasBatch) setBatchMode(false);

    run("Segment Image With Labkit",
        "input="            + inputTitle +
        " segmenter_file=[" + classifierPath + "]" +
        " use_gpu=false");
    rename("seg");

    if (wasBatch) setBatchMode(true);

    print("  Step 3: Labkit segmentation complete → 'seg'");
    return "seg";
}


// =====================================================================
//  STEP 4 — CLEAN THE SEGMENTATION MASK
//
//  Three sub-steps applied in sequence:
//
//  a) Binarise — convert Labkit's label image to strict 0 / 255.
//
//  b) Area Opening (per frame) — removes foreground objects smaller
//     than MIN_AREA pixels². This eliminates noise, debris, and small
//     false positives without eroding larger true cells. Operates
//     frame by frame because MorphoLibJ's Area Opening works on 2D
//     images, not stacks.
//
//  c) Median filter (full stack) — smooths jagged mask edges.
//
//  The per-frame loop runs in batch mode for speed, then turns it off
//  before returning so downstream steps can work with visible windows.
// =====================================================================
function cleanMask(maskTitle) {

    // a) Binarise the Labkit output
    selectWindow(maskTitle);
    setOption("BlackBackground", true);
    run("Convert to Mask", "background=Dark calculate black");
    rename("mask");
    maskTitle = "mask";

    // b) Per-frame Area Opening
    n = nSlices;
    frameTitles = newArray(n);

    setBatchMode(true);   // Speed up the frame-by-frame loop
    for (i = 1; i <= n; i++) {
        selectWindow(maskTitle);
        setSlice(i);
        // Duplicate this frame, remove small objects, store the result title.
        // Area Opening modifies the duplicate in place, so one window per frame.
        run("Duplicate...", "title=frame_" + IJ.pad(i, 4));
        run("Area Opening", "pixel=" + MIN_AREA);
        rename("clean_" + IJ.pad(i, 4));
        frameTitles[i-1] = "clean_" + IJ.pad(i, 4);
    }

    // Concatenate the cleaned frames back into a single stack
    outTitle   = "cleaned_mask";
    concatArgs = "title=[" + outTitle + "] open";
    for (i = 0; i < n; i++) concatArgs += " image" + (i+1) + "=[" + frameTitles[i] + "]";
    run("Concatenate...", concatArgs);

    // c) Median filter across the whole stack
    selectWindow(outTitle);
    run("Median...", "radius=" + MEDIAN_RADIUS + " stack");
    setBatchMode(false);

    print("  Step 4: area opening (>=" + MIN_AREA + " px²) + median r=" +
          MEDIAN_RADIUS + " on " + n + " frames → '" + outTitle + "'");
    return outTitle;
}


// =====================================================================
//  STEP 5 — MERGE MASK INTO ORIGINAL AS A NEW CHANNEL (IN PLACE)
//
//  Splits the original image into its individual channels, then merges
//  them back together with the cleaned mask appended as the final
//  channel. The merged composite is renamed to the original window
//  title, so the image is updated in place — no "_withMask" window.
//
//  How it works:
//    "Split Channels" closes the source and produces "C1-<title>",
//    "C2-<title>", etc. "Merge Channels" (without "keep") consumes
//    those inputs and produces a new composite, which we rename back
//    to the original title.
//
//  Example (3-ch input → 4-ch output):
//    Before: ch1 (anatomy) | ch2 (microglia) | ch3 (injured neurons)
//    After:  ch1 | ch2 | ch3 | ch4 (binary mask)
//
//  Note: "Merge Channels" supports up to 7 colour slots (c1–c7), so
//  the original image may have at most 6 channels for the mask to fit.
// =====================================================================
function addMaskAsChannel(originalTitle, maskTitle) {
    selectWindow(originalTitle);
    getDimensions(w, h, nCh, nZ, nT);

    mergeArgs = "";

    if (nCh > 1) {
        // "Split Channels" closes the source and creates windows named
        // "C1-<originalTitle>", "C2-<originalTitle>", ...
        run("Split Channels");
        for (c = 1; c <= nCh; c++) {
            mergeArgs += "c" + c + "=[C" + c + "-" + originalTitle + "] ";
        }
    } else {
        // Single-channel: reference the window directly — no split needed.
        mergeArgs += "c1=[" + originalTitle + "] ";
    }

    // Append the cleaned mask as the next channel.
    // "create" produces a new composite; omitting "keep" lets Merge consume
    // the input windows, leaving only the composite open.
    mergeArgs += "c" + (nCh + 1) + "=[" + maskTitle + "] create";
    run("Merge Channels...", mergeArgs);
    rename(originalTitle);   // Restore the original window title

    print("  Step 5: merged " + nCh + " original channel(s) + mask → '" +
          originalTitle + "' (" + (nCh + 1) + " channels total)");
}


// =====================================================================
//  STEP 6 — CLOSE INTERMEDIATE WINDOWS
//
//  Removes all working images created during the pipeline, leaving only
//  the modified original (which now has the mask as its final channel).
//  Uses closeIfOpen() throughout so no error is thrown if a window was
//  already consumed by a prior step (e.g. "cleaned_mask" is typically
//  consumed by Merge Channels in Step 5).
// =====================================================================
function cleanupWindows(originalTitle) {

    // Named intermediates with predictable titles
    junk = newArray(
        "work_ch" + CHANNEL_TO_KEEP,  // from Step 1 (extractChannel)
        "seg",                         // from Step 3 (renamed → "mask" inside cleanMask,
                                       //              but listed here as a safety net)
        "mask",                        // from Step 4a (binarised segmentation)
        "cleaned_mask"                 // from Step 4 (usually consumed by Merge in Step 5)
    );
    for (i = 0; i < junk.length; i++) closeIfOpen(junk[i]);

    // Sweep any windows that Merge Channels or Concatenate may not have consumed:
    //   "C1-<originalTitle>", "C2-<originalTitle>", ...  (from Split Channels, Step 5)
    //   "frame_NNNN", "clean_NNNN"                        (from the per-frame loop, Step 4)
    titles = getList("image.titles");
    for (i = 0; i < titles.length; i++) {
        t = titles[i];
        if (t == originalTitle) continue;   // Never close the result
        if (startsWith(t, "C") && endsWith(t, "-" + originalTitle)) closeIfOpen(t);
        if (startsWith(t, "frame_") || startsWith(t, "clean_"))      closeIfOpen(t);
    }

    // Confirm the final channel count and bring the result to the front
    if (isOpen(originalTitle)) {
        selectWindow(originalTitle);
        getDimensions(w, h, nCh, nZ, nT);
        print("  Step 6: cleanup complete — '" + originalTitle +
              "' now has " + nCh + " channels; mask is ch" + nCh + " (ready for Stage 4)");
    }
    run("Tile");
}


// ---- Helper: close a window by title only if it is currently open --
function closeIfOpen(title) {
    if (isOpen(title)) {
        selectWindow(title);
        close();
    }
}
