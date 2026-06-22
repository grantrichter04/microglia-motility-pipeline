/*
 * ============================================================================
 *  CHANNEL-2 MONTAGE BUILDER FOR LABKIT TRAINING
 * ============================================================================
 *
 *  PURPOSE
 *  -------
 *  Takes a parent folder containing many subfolders, each holding a
 *  multi-channel time-lapse MIP (maximum-intensity projection), and builds a
 *  single MONTAGE GRID where:
 *      - each tile = one time-lapse,
 *      - each tile holds only channel 2 (the marker we want to classify),
 *      - the stack's frame slider = shared TIME, so scrolling advances every
 *        tile through its own time points in lockstep.
 *  The result is one image you can hand to Labkit and annotate across all
 *  datasets at once, maximising the variety the classifier learns from.
 *
 *  WHY A MONTAGE (not a concatenation)?
 *  ------------------------------------
 *  We want every dataset visible simultaneously at each time point so we can
 *  compare and annotate them together. A montage tiles them in XY; time stays
 *  on the slider. Because tiles must be the same length for time to line up,
 *  shorter time-lapses are PADDED with blank frames at the end (harmless to
 *  the classifier as long as you don't annotate the blank tiles).
 *
 *  REQUIREMENTS
 *  ------------
 *  - Fiji (ImageJ + plugins), with the "Multi Stack Montage..." command
 *    available (Stitching/Grid tooling).
 *  - All source images should share width/height/bit depth for clean tiling.
 *
 *  OUTPUT
 *  ------
 *  channel2_montage.tif saved into the chosen parent folder.
 * ============================================================================
 */

// ---- USER SETTINGS ---------------------------------------------------------
cols = 5;                      // number of montage columns; rows auto-calculated
channelToKeep = 2;             // which channel to retain (the marker of interest)
suffix = "MIP.tif";            // only files ending with this are processed

// Ask the user to choose the parent folder. Everything one level below it
// (each subfolder) will be scanned for matching files.
parent = getDirectory("Choose the parent folder containing your dataset subfolders");

// Batch mode hides image windows while we work -> much faster, no flicker.
setBatchMode(true);
print("\\Clear");                // wipe the Log so each run starts clean

// ---- 1. OPEN + STRIP CHANNEL 2 FROM EVERY MATCHING FILE --------------------
// We walk each subfolder, open every *MIP.tif, and reduce it to channel 2.
// 'titles' collects the names of the resulting single-channel stacks so we
// can find them again for padding and montaging.
folderList = getFileList(parent);
titles = newArray(0);

for (i = 0; i < folderList.length; i++) {
    if (endsWith(folderList[i], "/")) {            // entries ending in "/" are subfolders
        sub = parent + folderList[i];
        files = getFileList(sub);
        for (j = 0; j < files.length; j++) {
            f = files[j];
            if (endsWith(f, suffix)) {             // only our target MIP files
                open(sub + f);
                orig = getTitle();
                getDimensions(w, h, ch, sl, fr);   // w,h, channels, z-slices, frames(time)

                // Safety guard: skip anything without a channel 2 so the run
                // doesn't crash on an unexpected single-channel file.
                if (ch < channelToKeep) {
                    print("SKIP (only " + ch + " channels): " + f);
                    close();
                } else {
                    // Arrange Channels keeps ONLY the listed channel(s), in place.
                    // 'new=2' -> collapse the 3-channel image down to just channel 2,
                    // while preserving the time axis. Result: single-channel time-lapse.
                    run("Arrange Channels...", "new=" + channelToKeep);

                    // Give it a clean, unique name derived from its source folder,
                    // so later we can trace each tile back to its dataset.
                    cleanName = "ch2_" + replace(folderList[i], "/", "");
                    rename(cleanName);

                    titles = Array.concat(titles, cleanName);
                    print("Kept ch" + channelToKeep + " of " + f + "  (" + fr + " frames)");
                }
            }
        }
    }
}

// If nothing matched, stop with a helpful message rather than failing silently.
n = titles.length;
if (n == 0) {
    setBatchMode(false);
    exit("No files ending in '" + suffix + "' found in subfolders of:\n" + parent);
}
print("Found " + n + " channel-2 stacks.");

// ---- 2. FIND THE LONGEST TIME-LAPSE ----------------------------------------
// To tile cleanly with a shared time axis, every stack must be the same length.
// First we find the maximum frame count; that becomes the common length.
// NOTE: after Arrange Channels each image is single-channel, so nSlices
// correctly reports the number of time points.
maxFrames = 0;
for (i = 0; i < n; i++) {
    selectWindow(titles[i]);
    nf = nSlices;
    if (nf > maxFrames) maxFrames = nf;
}
print("Maximum frames: " + maxFrames);

// ---- 3. PAD SHORTER STACKS UP TO THE COMMON LENGTH -------------------------
// Append blank frames to the END of any stack shorter than maxFrames.
// Padding at the tail keeps real data time-aligned from t=1; the blanks
// accumulate where the shorter datasets have simply finished.
// (Blank tiles are fine for the classifier provided you don't annotate them.)
for (i = 0; i < n; i++) {
    selectWindow(titles[i]);
    current = nSlices;
    if (current < maxFrames) {
        toAdd = maxFrames - current;
        print("Padding " + titles[i] + " by " + toAdd + " frames");
        setSlice(current);                 // move to the last real frame first
        for (k = 0; k < toAdd; k++) run("Add Slice");   // each adds one blank frame after it
    }
}

// ---- 4. BUILD THE MONTAGE GRID ---------------------------------------------
// Rows are derived from the number of stacks and chosen columns using
// ceiling division: rows = ceil(n / cols).
// We then build the parameter string the command expects:
//   stack_1=[name] stack_2=[name] ... rows=R columns=C
rows = floor((n + cols - 1) / cols);
stackParams = "";
for (i = 0; i < n; i++) {
    stackParams += "stack_" + (i+1) + "=[" + titles[i] + "] ";
}
stackParams += "rows=" + rows + " columns=" + cols;

print("Building Multi Stack Montage: " + rows + " rows x " + cols + " cols");
run("Multi Stack Montage...", stackParams);
rename("channel2_montage");

// ---- 5. SAVE THE RESULT ----------------------------------------------------
// Written into the chosen parent folder so it sits alongside the source data.
outPath = parent + "channel2_montage.tif";
saveAs("Tiff", outPath);
print("Saved montage to: " + outPath);

setBatchMode(false);
print("Done.");

/*
 * ----------------------------------------------------------------------------
 *  NEXT STEPS IN LABKIT
 *  --------------------
 *  1. Open channel2_montage.tif, right-click > Labkit (or Plugins > Labkit).
 *  2. Create one label per class (e.g. "signal", "background").
 *  3. Annotate SPARSELY but REPRESENTATIVELY: a few strokes per class across
 *     several tiles AND several time points - not every frame (adjacent
 *     frames are nearly identical and add little).
 *  4. Give each of the 10 datasets some strokes; roughly balance how much you
 *     annotate per dataset so none dominates the classifier.
 *  5. Do NOT paint on the blank (black) tail tiles of the padded datasets.
 *  6. Train, inspect the overlay, add corrective strokes where it errs,
 *     retrain. Repeat until happy, then save the .classifier file.
 * ----------------------------------------------------------------------------
 */