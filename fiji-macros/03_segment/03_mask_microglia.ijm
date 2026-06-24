// =====================================================================
//  LABKIT SEGMENTATION + MASK CLEANUP
// =====================================================================
//
//  Adds a cleaned binary microglia mask as an extra channel to a
//  multi-channel time-lapse, WITHOUT modifying the original. Choose at
//  launch whether to run on the active image only, or on every open image.
//
//  Per image, the pipeline:
//    1. records the original image title
//    2. duplicates the marker channel into a separate working image
//    3. ensures time is in FRAMES (not slices) so Labkit treats it as 2D/t
//    4. segments with Labkit
//    5. cleans the mask (binarise -> per-frame Area Opening -> median)
//    6. merges the cleaned mask back onto the ORIGINAL as a new channel
//  Output: the original image, now with an extra "mask" channel appended
//  (so a 3-channel input becomes a 4-channel "_withMask" composite).
// =====================================================================

// ---- CONFIG ---------------------------------------------------------
// DEFAULT_CLASSIFIER: optional convenience path to your .classifier file.
// Leave it as "" to be prompted to browse each time, OR paste your own
// path here (use double backslashes on Windows, e.g.
// "C:\\Users\\you\\models\\microglia.classifier") so it pre-fills.
var DEFAULT_CLASSIFIER = "";
var CHANNEL_TO_KEEP = 2;       // marker channel the classifier was trained on
var MIN_AREA = 800;            // minimum object size to keep (pixels)
var MEDIAN_RADIUS = 2;         // smoothing radius applied to the cleaned stack

// ---- SETUP: choose mode + classifier in one dialog ------------------
// Precompute the checkbox default: tick "browse" automatically when no
// default path is set. (The ImageJ macro parser won't accept a string
// comparison inline as a function argument, so we resolve it here first.)
browseByDefault = false;
if (lengthOf(DEFAULT_CLASSIFIER) == 0) browseByDefault = true;

Dialog.create("Microglia mask pipeline");
Dialog.addMessage("Labkit segmentation + mask cleanup");
Dialog.addRadioButtonGroup("Process:",
    newArray("Active image only", "All open images"), 2, 1, "Active image only");
Dialog.addString("Classifier path:", DEFAULT_CLASSIFIER, 60);
Dialog.addCheckbox("Browse for a file instead", browseByDefault);
Dialog.show();

mode = Dialog.getRadioButton();
classifierPath = Dialog.getString();
doBrowse = Dialog.getCheckbox();

// Browse if the box is ticked OR the field was left blank.
if (doBrowse || lengthOf(classifierPath) == 0) {
    picked = File.openDialog("Select your .classifier file");
    if (picked != "") classifierPath = picked;
}
if (lengthOf(classifierPath) == 0 || !File.exists(classifierPath))
    exit("Classifier not found:\n" + classifierPath);
print("Using classifier: " + classifierPath);

// ---- DISPATCH: single image or batch --------------------------------
if (mode == "All open images") {
    runBatch(classifierPath);
} else {
    if (nImages == 0) exit("No image open. Open a time-lapse first.");
    processOne(getTitle(), classifierPath);
    print("Pipeline complete: mask added as a channel to '" + getTitle() + "'");
}


// =====================================================================
//  BATCH DRIVER — run the pipeline on every currently-open image
// =====================================================================
function runBatch(classifierPath) {
    // Snapshot the originals NOW, before we create any intermediates.
    originals = getList("image.titles");

    // Filter out anything that looks like our own output, in case of a re-run.
    keep = newArray(0);
    for (i = 0; i < originals.length; i++) {
        if (endsWith(originals[i], "_withMask")) continue;   // skip previous composites
        keep = Array.concat(keep, originals[i]);
    }

    print("Batch: processing " + keep.length + " image(s).");

    for (i = 0; i < keep.length; i++) {
        originalTitle = keep[i];
        if (!isOpen(originalTitle)) continue;      // may have been closed by cleanup
        print("\n===== [" + (i+1) + "/" + keep.length + "] " + originalTitle + " =====");
        processOne(originalTitle, classifierPath);
        print("Done: '" + originalTitle + "_withMask'");
    }

    run("Tile");
    print("\nBatch complete.");
}

// =====================================================================
//  PER-IMAGE PIPELINE — the six steps for one time-lapse
// =====================================================================
function processOne(originalTitle, classifierPath) {
    selectWindow(originalTitle);
    workTitle  = extractChannel(originalTitle, CHANNEL_TO_KEEP); // 2. duplicate marker ch
    prepForLabkit(workTitle);                                    // 3. time -> frames
    segTitle   = segmentWithLabkit(workTitle, classifierPath, false); // 4. segment
    cleanTitle = cleanMask(segTitle);                            // 5. clean
    addMaskAsChannel(originalTitle, cleanTitle);                 // 6. merge back
    cleanupWindows(originalTitle, cleanTitle);                   // 7. close intermediates
}


// =====================================================================
//  MODULES
// =====================================================================

// Duplicate ONE channel of the source into a separate working image,
// leaving the original untouched. Returns the working image title.
function extractChannel(srcTitle, channel) {
    selectWindow(srcTitle);
    workTitle = "work_ch" + channel;
    // duplicate=hyperstack with channels=N keeps all time points of that channel
    run("Duplicate...", "title=" + workTitle + " duplicate channels=" + channel);
    print("Extracted channel " + channel + " of '" + srcTitle + "' -> '" + workTitle + "'");
    return workTitle;
}

// Ensure the working image has time in FRAMES, not slices.
function prepForLabkit(workTitle) {
    selectWindow(workTitle);
    getDimensions(w, h, c, z, t);
    nPlanes = z * t;
    if (z > 1 && t == 1) {                 // time mislabelled as slices -> fix
        run("Properties...", "channels=1 slices=1 frames=" + nPlanes);
        print("Moved time from slices to frames on '" + workTitle + "'");
    }
}

// Run Labkit, immediately rename result to a short, safe title.
function segmentWithLabkit(inputTitle, classifierPath, useGpu) {
    gpuFlag = "false";
    if (useGpu) gpuFlag = "true";
    selectWindow(inputTitle);
    run("Segment Image With Labkit",
        "input=" + inputTitle +
        " segmenter_file=[" + classifierPath + "]" +
        " use_gpu=" + gpuFlag);
    rename("seg");
    print("Segmented '" + inputTitle + "' -> 'seg'");
    return "seg";
}

// Clean the segmentation: binarise -> per-frame Area Opening -> median.
// Returns the cleaned stack title.
function cleanMask(maskTitle) {
    selectWindow(maskTitle);
    setOption("BlackBackground", true);
    run("Convert to Mask", "background=Dark calculate black");
    rename("mask");
    maskTitle = "mask";

    n = nSlices;
    frameTitles = newArray(n);
    setBatchMode(true);

    for (i = 1; i <= n; i++) {
        selectWindow(maskTitle);
        setSlice(i);
        srcFrame = "frame_" + IJ.pad(i, 4);
        run("Duplicate...", "title=" + srcFrame);
        run("Area Opening", "pixel=" + MIN_AREA);
        cleanName = "clean_" + IJ.pad(i, 4);
        rename(cleanName);
        frameTitles[i-1] = cleanName;
        if (isOpen(srcFrame)) { selectWindow(srcFrame); close(); }
    }

    outTitle = "cleaned_mask";
    concatArgs = "  title=[" + outTitle + "] open";
    for (i = 0; i < n; i++) {
        concatArgs += " image" + (i+1) + "=[" + frameTitles[i] + "]";
    }
    run("Concatenate...", concatArgs);

    selectWindow(outTitle);
    run("Median...", "radius=" + MEDIAN_RADIUS + " stack");

    setBatchMode(false);
    print("cleanMask: area-opened " + n + " frames (>=" + MIN_AREA +
          " px) + median r" + MEDIAN_RADIUS + " -> '" + outTitle + "'");
    return outTitle;
}

// Merge the cleaned mask onto the ORIGINAL as an extra channel.
// Merge Channels needs single-channel inputs, so we split the original
// first, then recombine its channels + the mask into one composite.
//
// GENERALISED: the original channel count is read at run time, so this
// works for any number of input channels (the mask is appended as the
// next channel after the originals). NOTE: ImageJ's "Merge Channels..."
// supports up to 7 colour slots (c1..c7), so the input may have at most
// 6 channels for the mask to fit as the 7th.
function addMaskAsChannel(originalTitle, maskTitle) {
    selectWindow(originalTitle);
    getDimensions(w, h, nCh, nZ, nT);

    // Work on a copy so we don't disturb the original.
    run("Duplicate...", "title=orig_copy duplicate");

    // Build the Merge Channels argument string for however many channels exist.
    mergeArgs = "";
    if (nCh > 1) {
        // Split Channels produces "C1-orig_copy", "C2-orig_copy", ...
        run("Split Channels");
        for (c = 1; c <= nCh; c++) {
            mergeArgs += "c" + c + "=[C" + c + "-orig_copy] ";
        }
    } else {
        // Single-channel: no split happens; the copy keeps its title.
        mergeArgs += "c1=[orig_copy] ";
    }
    // Append the mask as the next channel after the originals.
    mergeArgs += "c" + (nCh + 1) + "=[" + maskTitle + "] create keep";

    run("Merge Channels...", mergeArgs);
    rename(originalTitle + "_withMask");
    print("Built " + (nCh + 1) + "-channel composite '" + originalTitle +
          "_withMask' (orig " + nCh + " ch + mask)");
}

// =====================================================================
//  Close every window the pipeline created, EXCEPT the original image
//  and the final "<original>_withMask" composite.
// =====================================================================
function cleanupWindows(originalTitle, cleanTitle) {
    finalTitle = originalTitle + "_withMask";

    // Explicit list of the intermediates this pipeline is known to create.
    // C-prefixed split windows are handled by the prefix sweep below, so we
    // don't need to hardcode how many there were.
    junk = newArray(
        "work_ch" + CHANNEL_TO_KEEP,   // extractChannel
        "seg",                         // segmentWithLabkit
        "mask",                        // cleanMask (binarised)
        "cleaned_mask",                // cleanMask output
        cleanTitle,                    // whatever cleanMask returned (usually "cleaned_mask")
        "orig_copy"                    // addMaskAsChannel working copy (single-channel case)
    );

    for (i = 0; i < junk.length; i++) {
        closeIfOpen(junk[i]);
    }

    // Sweep up any remaining temporaries by prefix: the split channels
    // ("C1-orig_copy" ...) and the per-frame temporaries from cleanMask
    // ("frame_0001" / "clean_0001") if it bailed out mid-loop.
    titles = getList("image.titles");
    for (i = 0; i < titles.length; i++) {
        t = titles[i];
        if (t == originalTitle || t == finalTitle) continue;   // never close the keepers
        if (startsWith(t, "C") && endsWith(t, "-orig_copy")) closeIfOpen(t);
        else if (startsWith(t, "frame_") || startsWith(t, "clean_")) closeIfOpen(t);
    }

    // Tidy the display of what remains.
    if (isOpen(finalTitle)) selectWindow(finalTitle);
    run("Tile");

    print("Cleanup complete: kept '" + originalTitle + "' and '" + finalTitle + "'");
}

// Close a window by title only if it actually exists (no error if missing).
function closeIfOpen(title) {
    if (isOpen(title)) {
        selectWindow(title);
        close();
    }
}
