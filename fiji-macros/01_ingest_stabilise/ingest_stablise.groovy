#@ String (visibility=MESSAGE, value="<html><body style='width:520px'><b>LIF drift-correction pipeline.</b> Corrects slow sample drift in every series of a Leica .lif using Fast4DReg (drift measured on the reference channel, then applied identically to all channels). For each series it saves a drift-corrected 5D stack and a max-intensity projection. A timestamped RUN_LOG and a METHODS draft are written to the output folder.</body></html>") header
#@ ModuleService ms
#@ File    (label = "Input .lif file", style = "open")                       lifFile
#@ File    (label = "Output base directory", style = "directory")            outBase
#@ Integer (label = "Reference channel (1-based)", value = 1)                refChannel
#@ Integer (label = "Number of series to process (0 = all)", value = 2)      maxSeries
#@ Boolean (label = "Correct XY drift", value = true)                        doXY
#@ Boolean (label = "Correct Z drift",  value = true)                        doZ
#@ String  (label = "XY projection", choices={"Max Intensity","Average Intensity"}, value="Max Intensity") projXY
#@ String  (label = "Z projection",  choices={"Max Intensity","Average Intensity"}, value="Max Intensity") projZ
#@ Integer (label = "XY time averaging (1 = none)", value = 1)               timeXY
#@ Integer (label = "Z time averaging (1 = none)",  value = 1)               timeZ
#@ Integer (label = "XY max expected drift (0 = auto)", value = 0)           maxXY
#@ Integer (label = "Z max expected drift (0 = auto)",  value = 0)           maxZ
#@ String  (label = "XY reference frame", choices={"previous frame (better for live)","first frame (default, better for fixed)"}, value="previous frame (better for live)") refXY
#@ String  (label = "Z reference frame",  choices={"previous frame (better for live)","first frame (default, better for fixed)"}, value="previous frame (better for live)") refZ
#@ Boolean (label = "Crop output", value = false)                            cropOutput
#@ String  (label = "Z reslice mode", choices={"Top","Left"}, value="Top")   resliceMode
#@ Boolean (label = "Extend stack to fit", value = false)                    extendStack
#@ Boolean (label = "Save RAM", value = false)                               saveRAM
#@ String  (label = "Channel 1 LUT", choices={"Blue","Green","Red","Cyan","Magenta","Yellow","Grays","Fire","Orange Hot","Ice"}, value="Blue")       lut1
#@ String  (label = "Channel 2 LUT", choices={"Orange Hot","Green","Red","Cyan","Magenta","Yellow","Grays","Fire","Blue","Ice"}, value="Orange Hot") lut2
#@ String  (label = "Channel 3 LUT", choices={"Green","Red","Cyan","Magenta","Yellow","Grays","Fire","Blue","Orange Hot","Ice"}, value="Green")      lut3
#@ Boolean (label = "Cleanup redundant intermediates (keeps drift data)", value = false) doCleanup
#@ String  (label = "Output bit depth", choices={"Match source (smaller files)","Keep Fast4DReg 32-bit"}, value="Match source (smaller files)") outputBitDepth

/* =====================================================================
 *  LIF DRIFT-CORRECTION PIPELINE  (Groovy)  —  v7
 * =====================================================================
 *
 *  Author:        Grant Richter
 *  Contributions: Claude (Anthropic) — run-logging & methods-diary refactor;
 *                 name-based cleanup; frame-interval (temporal calibration)
 *                 preservation; optional output bit-depth match to source
 *                 (undoes Fast4DReg's incidental 32-bit float promotion);
 *                 per-series batch progress (count / % / elapsed / ETA) and
 *                 per-series freed-space reporting; bit-depth note in METHODS.
 *                 (Final assembly uses the standard window-based path — it
 *                 draws briefly, by design.)
 *  Date:          2026-06-17
 *
 *  WHAT THIS SCRIPT DOES, AT A GLANCE:
 *
 *   +-------------------------------------------------------------+
 *   |  .lif container  (holds many recordings = "series")         |
 *   +-------------------------------------------------------------+
 *                              |  open with Bio-Formats,
 *                              v  step through each series
 *   +-------------------------------------------------------------+
 *   |  ONE SERIES  =  5D image (X, Y, Z, 3 Channels, Time)        |
 *   +-------------------------------------------------------------+
 *                              |  STEP 1: split the colours apart
 *                              v
 *        +-------------+   +-------------+   +-------------+
 *        |  Channel 1  |   |  Channel 2  |   |  Channel 3  |
 *        +-------------+   +-------------+   +-------------+
 *              |  STEP 2: measure drift on the reference
 *              v  channel, then apply SAME shift to all 3
 *        +-------------+   +-------------+   +-------------+
 *        | Ch1 aligned |   | Ch2 aligned |   | Ch3 aligned |
 *        +-------------+   +-------------+   +-------------+
 *                              |  STEP 3: recombine the colours
 *                              v
 *   +-------------------------------------------------------------+
 *   |  Drift-corrected, 3-colour 5D image  (+ apply LUTs)         |
 *   +-------------------------------------------------------------+
 *                +-------------+-------------+
 *                | save as-is                | STEP 4: flatten Z
 *                v (full 5D stack)           v (max-intensity proj.)
 *   +-------------------------+   +-------------------------------+
 *   |  Corrected 5D stack     |   |  Max-intensity projection     |
 *   |  (.tif) -> saved        |   |  (.tif) -> saved              |
 *   +-------------------------+   +-------------------------------+
 *
 *   ( ... repeats for each series ... )
 *
 *  PROVENANCE: drift correction is performed by Fast4DReg v2.1
 *  (Pylvanainen et al. 2022; doi:10.1242/jcs.260728), which itself
 *  uses NanoJ-Core (Laine et al. 2019; doi:10.1088/1361-6463/ab0261).
 *  Their UNMODIFIED, update-site-installed scripts are invoked here via
 *  the SciJava ModuleService (no copy/fork of their code).
 *
 *  HOW TO READ THIS FILE: lines in /* ... *\/ and after "//" are notes
 *  for humans; everything else is instructions the computer follows.
 * ===================================================================== */

import ij.IJ
import ij.ImagePlus
import ij.WindowManager
import ij.process.ImageConverter
import ij.process.StackConverter
import java.io.File
import java.text.SimpleDateFormat

// ---- Portable module identifiers (machine-agnostic; no disk paths) ----
ESTIMATE_ID = "script:Fast4DReg/time_estimate+apply.ijm"
APPLY_ID    = "script:Fast4DReg/time_apply.ijm"

// ---- A growing "methods diary" we print (and save) at the end ----
methodsLog = new StringBuilder()

// =====================================================================
//  DURABLE RUN LOG  — survives third-party \Clear of the Log window.
// ---------------------------------------------------------------------
//  The ImageJ Log window is a single shared surface: any macro can wipe
//  it with the "\Clear" directive, and the Fast4DReg / Bio-Formats
//  macros invoked below do exactly that. So we never trust the window as
//  the record. Every progress line goes to a TEXT FILE on disk (cannot
//  be cleared), and is mirrored to the Log window + status bar for live
//  viewing. One helper -> no more IJ.log/println split, and the same
//  record whether the run has a UI or is headless.
//  NOTE: declared WITHOUT 'def' so they live in the script binding and
//  are visible inside the helper methods below.
// =====================================================================
runLogFile = null                                   // File, opened in main()
runStartMs = System.currentTimeMillis()             // t0 for elapsed timer

def String tStamp()  { new SimpleDateFormat("HH:mm:ss").format(new Date()) }

def String tElapsed() {
    long s = (long)((System.currentTimeMillis() - runStartMs) / 1000L)
    return String.format("%d:%02d", (s / 60) as int, (s % 60) as int)
}

// Format an arbitrary millisecond duration as H:MM:SS (or M:SS under an hour).
def String fmtDur(long ms) {
    if (ms < 0) ms = 0
    long s = (long)(ms / 1000L)
    long h = s / 3600L, m = (s % 3600L) / 60L, sec = s % 60L
    return (h > 0) ? String.format("%d:%02d:%02d", h, m, sec)
                   : String.format("%d:%02d", m, sec)
}

// Single entry point for human-facing progress: timestamped + durable.
def say(String msg) {
    String line = "[" + tStamp() + "  +" + tElapsed() + "]  " + msg
    IJ.log(line)                                     // live window (may be cleared)
    IJ.showStatus(msg)                               // status bar (separate surface)
    System.out.println(line)                         // console / headless capture
    if (runLogFile != null) {
        try { runLogFile << line + System.lineSeparator() } catch (Throwable ignore) {}
    }
}

// Verbatim multi-line block (no per-line timestamp): for the methods draft.
def dump(String text) {
    IJ.log(text)
    if (runLogFile != null) {
        try { runLogFile << text + System.lineSeparator() } catch (Throwable ignore) {}
    }
}


// =====================================================================
//  MAIN ORCHESTRATION  — drives the per-series flow (the ASCII roadmap)
// =====================================================================
def main() {
    // Open a durable run-log file FIRST, before any third-party macro runs.
    String tag = new SimpleDateFormat("yyyyMMdd_HHmmss").format(new Date())
    runLogFile = new File(outBase, "RUN_LOG_" + tag + ".txt")
    runLogFile.text = "LIF drift-correction run log — started " + new Date() + "\n\n"

    IJ.log("\\Clear")                               // clear the window once, at the start
    say("==== LIF drift-correction pipeline starting ====")
    say("Input file:  " + lifFile.getName())
    say("Output base: " + outBase.getAbsolutePath())
    say("Run log:     " + runLogFile.getName())

    // Discover how many series the .lif holds, using Bio-Formats headlessly.
    int seriesCount = countSeries(lifFile)
    say("Series found in file: " + seriesCount)

    int nToProcess = seriesCount
    if (maxSeries > 0 && maxSeries < seriesCount) nToProcess = maxSeries
    say("This run will process " + nToProcess + " of " + seriesCount + " series.")
    say("Reference channel = " + refChannel + " | XY = " + doXY + " | Z = " + doZ)

    // Process each series in turn, tracking success/failure for a final tally.
    // A per-series progress line (count, %, elapsed, ETA) is emitted through
    // say(), so the batch loop is recorded in the console, the macro Log
    // window AND the run-log file. The Log window may be cleared by Fast4DReg
    // mid-series, but this line is re-printed AFTER each series, so the live
    // window always shows the current batch position once a series finishes.
    int nDone = 0, nFailed = 0
    long loopStartMs = System.currentTimeMillis()
    for (int s = 0; s < nToProcess; s++) {
        say("======== Series " + (s + 1) + "/" + nToProcess +
            "  (file index " + s + ") ========")
        IJ.showProgress(s, nToProcess)              // progress bar, separate from Log
        try {
            processOneSeries(s)
            nDone++
            say("Series " + (s + 1) + "/" + nToProcess + " complete  (" +
                nDone + " done, " + nFailed + " failed so far).")
        } catch (Throwable t) {
            // One bad series shouldn't sink the whole batch — log and move on.
            nFailed++
            say("!! Series " + s + " FAILED: " + t.getClass().getSimpleName() +
                ": " + t.getMessage())
        }

        // Batch heartbeat: where we are, how long it's taken, and a rough ETA
        // (simple running average of time per series so far).
        int attempted = s + 1
        long elapsedMs = System.currentTimeMillis() - loopStartMs
        long etaMs = (long)((elapsedMs / (double) attempted) * (nToProcess - attempted))
        int pct = (int) Math.round(100.0 * attempted / nToProcess)
        say("Batch progress: " + attempted + "/" + nToProcess + " (" + pct + "%)" +
            " | elapsed " + fmtDur(elapsedMs) +
            " | est. remaining " + fmtDur(etaMs))
    }
    IJ.showProgress(1.0)

    // Write the assembled methods paragraph next to the outputs.
    writeMethods()
    say("==== Pipeline complete: " + nDone + " succeeded, " + nFailed +
        " failed, of " + nToProcess + " attempted. ====")
    say("Full diary saved to: " + runLogFile.getAbsolutePath())
}


// =====================================================================
//  BRICK: count how many series are inside the .lif
//  Uses Bio-Formats macro extensions purely to read the series count.
// =====================================================================
def int countSeries(File lif) {
    
    // Ext.* commands are macro-only, so we run a tiny macro and read back.
    String n = IJ.runMacro(
        "run('Bio-Formats Macro Extensions');" +
        "Ext.setId('" + lif.getAbsolutePath().replace("\\", "\\\\") + "');" +
        "Ext.getSeriesCount(c);" +
        "return '' + c;")
    return Integer.parseInt(n.trim())
}


// =====================================================================
//  PER-SERIES PIPELINE  — runs all the bricks for a single recording
// =====================================================================
def processOneSeries(int s) {

    // ---- BRICK 1: extract this series and split its channels to disk ----
    def info = extractAndSplitSeries(s)      // returns map: dir, safeName, channels, slices, frames
    File seriesDir = info.dir
    String safeName = info.safeName
    int channels   = info.channels
    say("Series '" + safeName + "': C=" + channels +
        " Z=" + info.slices + " T=" + info.frames)

    if (channels < 3) {
        say("!! Expected 3 channels, found " + channels + " — skipping series.")
        return
    }

    // Paths to the three single-channel files we just saved.
    def chFile = { int c -> new File(seriesDir, "C" + c + "_" + safeName + ".tif") }

    // ---- BRICK 2a: estimate + apply drift on the REFERENCE channel ----
    // Snapshot existing subfolders so we can find the new timestamped one.
    def before = listSubdirs(seriesDir)
    runEstimateAndApply(chFile(refChannel))
    def after = listSubdirs(seriesDir)
    File estimateDir = findNewDir(seriesDir, before, after)
    if (estimateDir == null)
        throw new RuntimeException("Could not locate Fast4DReg output folder for reference channel.")
    File settingsCsv = findSettingsCsv(estimateDir)
    say("  Estimate output folder: " + estimateDir.getName())
    say("  Settings file: " + settingsCsv.getName())

    // ---- BRICK 2b: apply that correction to the OTHER channels ----
    // Each non-reference channel gets its own apply-output folder.
    def correctedFiles = [:]                 // channel index -> final corrected File
    correctedFiles[refChannel] = findFinalCorrected(estimateDir, "C" + refChannel + "_" + safeName)

    for (int c = 1; c <= channels; c++) {
        if (c == refChannel) continue
        File applyDir = new File(seriesDir, "C" + c + "_applied")
        applyDir.mkdirs()
        runApply(chFile(c), settingsCsv, applyDir)
        correctedFiles[c] = findFinalCorrected(applyDir, "C" + c + "_" + safeName)
    }

    // ---- Dimension guard: all three must match before merging ----
    if (!dimensionsMatch(correctedFiles.values())) {
        say("!! Corrected channels have mismatched dimensions — skipping merge for this series.")
        return
    }

    // ---- Decide output bit depth: native acquisition depth, or keep float ----
    boolean convertOutput = outputBitDepth.startsWith("Match")
    int targetBitDepth = convertOutput ? info.bitDepth : 32
    say("  Output bit depth: " + (convertOutput
            ? (info.bitDepth + "-bit (matched to source; Fast4DReg's 32-bit float dropped)")
            : "32-bit float (kept as produced by Fast4DReg)"))

    // ---- BRICK 3: merge the corrected channels (original order, composite) ----
    //  NOTE: this assembly opens / merges / projects via the standard ImageJ
    //  window commands, so it WILL briefly pop up image windows. That is
    //  accepted on purpose: it's the most robust path across Fiji builds.
    //  (An earlier attempt to suppress these with batch mode hit a
    //  version-specific API gap — IJ.setBatchMode(boolean) isn't present in
    //  every build — so we keep the working window-based version.) The
    //  windows are closed again immediately below.
    ImagePlus merged = mergeChannels(correctedFiles, channels, targetBitDepth)
    applyLUTs(merged)                            // colour each channel
    restoreFrameInterval(merged, info.frameInterval, info.timeUnit)   // re-stamp lost time calibration
    File mergedOut = new File(seriesDir, safeName + "_corrected_xyz.tif")
    IJ.saveAs(merged, "Tiff", mergedOut.getAbsolutePath())
    say("  Saved corrected 5D stack: " + mergedOut.getName() +
        "  (frame interval " + info.frameInterval + " " + info.timeUnit + ")")

    // ---- BRICK 4: max-intensity projection over Z (channels + time kept) ----
    ImagePlus mip = maxProject(merged)
    restoreFrameInterval(mip, info.frameInterval, info.timeUnit)      // belt-and-suspenders
    File mipOut = new File(seriesDir, safeName + "_corrected_xyz_MIP.tif")
    IJ.saveAs(mip, "Tiff", mipOut.getAbsolutePath())
    say("  Saved MIP: " + mipOut.getName())

    // Close every intermediate window so nothing lingers.
    mip.close()
    merged.close()
    closeByTitlePrefix("CORR_C")                 // the three opened channels, if any remain

    // ---- Optional cleanup (filesystem only; off by default; keeps drift data) ----
    if (doCleanup) cleanup(seriesDir, safeName)

    // ---- Methods diary: write the generic sentences once (first series) ----
    if (methodsLog.length() == 0) appendMethods(channels, info.bitDepth, convertOutput)
}


// =====================================================================
//  BRICK 1: extract one series from the .lif and split its channels.
//  Opens just this series as a 5D hyperstack, splits the colours, and
//  saves each channel as its own TIFF (full XYZT) for drift correction.
// =====================================================================
def extractAndSplitSeries(int s) {
    // Discover a tidy, filesystem-safe name for this series.
    String rawName = seriesName(lifFile, s)
    String safeName = sanitiseName(rawName)
    if (safeName == "") safeName = "series_" + String.format("%03d", s)

    File seriesDir = new File(outBase, safeName)
    if (!seriesDir.exists()) seriesDir.mkdirs()

    // Open this one series (importer counts series from 1, hence s+1).
    String opts = "open=[" + lifFile.getAbsolutePath() + "] color_mode=Default " +
                  "view=Hyperstack stack_order=XYCZT specify_range series_" + (s + 1)
    IJ.run("Bio-Formats Importer", opts)

    ImagePlus imp = IJ.getImage()
    String title = imp.getTitle()
    int[] dims = imp.getDimensions()          // [w, h, channels, slices, frames]
    int channels = dims[2]
    int slices   = dims[3]
    int frames   = dims[4]

    // Capture the TEMPORAL calibration now, while Bio-Formats still has it.
    // Spatial calibration (pixel size, voxel depth) survives processing, but
    // the frame interval is dropped downstream (e.g. by Fast4DReg's re-save),
    // so we stash it here and re-stamp it onto the final outputs.
    def cal = imp.getCalibration()
    double frameInterval = cal.frameInterval
    String timeUnit = cal.getTimeUnit()

    // Capture the acquisition bit depth too. Fast4DReg promotes everything to
    // 32-bit float (sub-pixel interpolation needs it); we use this to bring
    // the final outputs back to the native depth if the user asked for it.
    int bitDepth = imp.getBitDepth()

    // Split colours and save each channel.
    if (channels > 1) {
        IJ.run(imp, "Split Channels", "")
        for (int c = 1; c <= channels; c++) {
            ImagePlus chImp = WindowManager.getImage("C" + c + "-" + title)
            File outPath = new File(seriesDir, "C" + c + "_" + safeName + ".tif")
            IJ.saveAs(chImp, "Tiff", outPath.getAbsolutePath())
            chImp.close()
        }
    } else {
        File outPath = new File(seriesDir, "C1_" + safeName + ".tif")
        IJ.saveAs(imp, "Tiff", outPath.getAbsolutePath())
        imp.close()
    }

    return [dir: seriesDir, safeName: safeName,
            channels: channels, slices: slices, frames: frames,
            frameInterval: frameInterval, timeUnit: timeUnit, bitDepth: bitDepth]
}


// =====================================================================
//  BRICK 2a: run Fast4DReg "time estimate+apply" on the reference channel.
//  Invokes their UNMODIFIED installed script via the ModuleService, with
//  our parameter map (the mechanism we proved works: process=false).
// =====================================================================
def runEstimateAndApply(File channelFile) {
    def info = ms.getModules().find { it.getIdentifier() == ESTIMATE_ID }
    if (info == null) throw new RuntimeException("Module not found: " + ESTIMATE_ID)

    def params = [
        "exp_nro"               : 1,
        "files"                 : ([channelFile] as File[]),
        "XY_registration"       : doXY,
        "projection_type_xy"    : projXY,
        "time_xy"               : timeXY,
        "max_xy"                : maxXY,
        "reference_xy"          : refXY,
        "crop_output"           : cropOutput,
        "z_registration"        : doZ,
        "projection_type_z"     : projZ,
        "reslice_mode"          : resliceMode,
        "time_z"                : timeZ,
        "max_z"                 : maxZ,
        "reference_z"           : refZ,
        "extend_stack_to_fit"   : extendStack,
        "ram_conservative_mode" : saveRAM
    ] as Map

    say("  Running estimate+apply on " + channelFile.getName() + " ...")
    ms.run(info, false, params).get()
    say("  ...estimate+apply finished for " + channelFile.getName())
}


// =====================================================================
//  BRICK 2b: run Fast4DReg "time apply" on a non-reference channel,
//  using the settings.csv produced by the reference-channel estimate.
// =====================================================================
def runApply(File channelFile, File settingsCsv, File resultsDir) {
    def info = ms.getModules().find { it.getIdentifier() == APPLY_ID }
    if (info == null) throw new RuntimeException("Module not found: " + APPLY_ID)

    def params = [
        "files"              : ([channelFile] as File[]),
        "settings_file_path" : settingsCsv,
        "results_path"       : resultsDir
    ] as Map

    say("  Running apply on " + channelFile.getName() + " ...")
    ms.run(info, false, params).get()
    say("  ...apply finished for " + channelFile.getName())
}


// =====================================================================
//  BRICK 3: merge corrected single-channel stacks into one composite,
//  in ORIGINAL channel order (C1->c1, C2->c2, C3->c3).
// =====================================================================
def ImagePlus mergeChannels(Map correctedFiles, int channels, int targetBitDepth) {
    // Open each corrected channel and build the "Merge Channels" arg string.
    // Each channel is converted to the target depth here, BEFORE merging, so
    // the conversion happens on a simple single-channel image with one
    // unambiguous display range (see downconvertTo). The merge, LUTs and
    // projection downstream then all inherit that depth.
    StringBuilder arg = new StringBuilder()
    for (int c = 1; c <= channels; c++) {
        ImagePlus imp = IJ.openImage(correctedFiles[c].getAbsolutePath())
        downconvertTo(imp, targetBitDepth)
        imp.setTitle("CORR_C" + c)
        imp.show()
        arg.append("c").append(c).append("=[CORR_C").append(c).append("] ")
    }
    arg.append("create")                      // 'create' = composite (keeps channels separate)
    IJ.run("Merge Channels...", arg.toString().trim())
    ImagePlus merged = IJ.getImage()
    return merged
}


// =====================================================================
//  BRICK 3b: reset each channel's contrast (undo Fast4DReg's Enhance
//  Contrast) and apply the user-chosen LUT. Missing LUT -> warn, not crash.
// =====================================================================
def applyLUTs(ImagePlus merged) {
    def luts = [1: lut1, 2: lut2, 3: lut3]
    int nC = merged.getNChannels()
    for (int c = 1; c <= nC; c++) {
        // land on a representative slice and read the true data range
        merged.setPosition(c, (merged.getNSlices() / 2) as int, 1)
        def ip = merged.getProcessor()
        ip.resetMinAndMax()
        double mn = ip.getMin()
        double mx = ip.getMax()
        merged.setC(c)
        merged.setDisplayRange(mn, mx)          // restore sensible contrast
        String lutName = luts[c]
        if (lutName == null) continue
        try {
            IJ.run(merged, lutName, "")
            say("    C" + c + " -> LUT '" + lutName +
                "', display range [" + mn + ", " + mx + "]")
        } catch (Throwable t) {
            say("    !! Could not apply LUT '" + lutName + "' to channel " +
                c + " (" + t.getMessage() + ") — leaving default.")
        }
    }
    if (merged instanceof ij.CompositeImage)
        ((ij.CompositeImage) merged).setMode(ij.CompositeImage.COMPOSITE)
    merged.updateAndDraw()
}


// =====================================================================
//  BRICK 4: maximum-intensity projection over Z, preserving channels
//  AND time. The 'all' flag is essential — without it, ZProjector
//  collapses time as well as Z. (Confirmed by GUI macro recording.)
// =====================================================================
def ImagePlus maxProject(ImagePlus merged) {
    IJ.run(merged, "Z Project...", "projection=[Max Intensity] all")
    ImagePlus mip = IJ.getImage()              // the new MAX_ window is now front
    return mip
}


// =====================================================================
//  OPTIONAL CLEANUP: remove only redundant IMAGE intermediates.
//  KEEPS: corrected 5D stack, MIP, and the entire Fast4DReg estimate
//  folder (drift tables, plots, settings.csv = your quantitative record).
//  REMOVES: the split single-channel inputs, and — for each NON-reference
//  channel's "_applied" folder — the known Fast4DReg corrected outputs,
//  then the folder itself ONLY if it is empty afterwards.
//
//  SAFETY: this never uses a recursive delete. Files are removed by exact
//  name, and the folder is removed with File.delete(), which deletes an
//  EMPTY directory only — it silently refuses (returns false) on anything
//  that still has contents. So if Fast4DReg ever leaves an unexpected file
//  behind, the folder is KEPT and reported, not blown away. Every delete is
//  logged truthfully from its return value (no more "removed" on failure).
// =====================================================================
def cleanup(File seriesDir, String safeName) {
    say("  Cleanup: removing redundant image intermediates ...")
    long freed = 0L

    // 1. The split single-channel inputs (now baked into the final stack).
    for (int c = 1; c <= 3; c++) {
        freed += deleteFileByName(new File(seriesDir, "C" + c + "_" + safeName + ".tif"))
    }

    // 2. Each non-reference channel's apply folder. The reference channel has
    //    no "_applied" folder (its outputs live in the estimate folder), so
    //    it is never touched here.
    for (int c = 1; c <= 3; c++) {
        if (c == refChannel) continue
        File applyDir = new File(seriesDir, "C" + c + "_applied")
        if (!applyDir.isDirectory()) continue

        // Delete the known corrected outputs for this channel, by exact name.
        // Covers all correction modes (xy+z -> intermediate + final; z-only;
        // xy-only). Only files that exist are touched.
        String stem = "C" + c + "_" + safeName
        for (String suf : ["_xyzCorrected.tif", "_xyCorrected.tif", "_zCorrected.tif"]) {
            freed += deleteFileByName(new File(applyDir, stem + suf))
        }

        // Remove the folder ONLY if it is now empty (safe: refuses otherwise).
        if (applyDir.delete()) {
            say("    removed folder " + applyDir.getName())
        } else {
            String[] left = applyDir.list()
            int n = (left == null) ? -1 : left.length
            say("    kept folder " + applyDir.getName() +
                " (not empty — " + n + " item(s) remain; left in place)")
        }
    }

    say("  Cleanup freed ~" + String.format("%.1f", freed / 1048576.0) +
        " MB for this series.")
}

// Delete one file by its exact path; log truthfully and return bytes freed.
def long deleteFileByName(File f) {
    if (f == null || !f.exists()) return 0L
    long sz = f.length()
    if (f.delete()) { say("    removed " + f.getName()); return sz }
    say("    !! could NOT remove " + f.getName())
    return 0L
}


// =====================================================================
//  SMALL HELPER BRICKS
// =====================================================================

// Pick the correct final corrected file based on which corrections ran.
def File findFinalCorrected(File dir, String stem) {
    String suffix
    if (doXY && doZ)      suffix = "_xyzCorrected.tif"
    else if (doZ)         suffix = "_zCorrected.tif"
    else                  suffix = "_xyCorrected.tif"
    File f = new File(dir, stem + suffix)
    if (!f.exists()) {
        // Fallback: search the folder for anything ending in the suffix.
        File found = dir.listFiles().find { it.getName().endsWith(suffix) }
        if (found != null) return found
        throw new RuntimeException("No corrected file ending '" + suffix + "' in " + dir)
    }
    return f
}

// List the subfolders of a directory (used for the before/after diff).
def List listSubdirs(File dir) {
    return dir.listFiles().findAll { it.isDirectory() }.collect { it.getName() }
}

// Find the one new subfolder that appeared after running estimate+apply.
def File findNewDir(File parent, List before, List after) {
    def added = after - before
    if (added.isEmpty()) return null
    String pick = added.find { it.startsWith("C" + refChannel + "_") }
    if (pick == null) pick = added[0]
    return new File(parent, pick)
}

// The settings.csv inside an estimate output folder.
def File findSettingsCsv(File estimateDir) {
    File found = estimateDir.listFiles().find { it.getName().endsWith("_settings.csv") }
    if (found == null) throw new RuntimeException("No settings.csv in " + estimateDir)
    return found
}

// Check that all corrected stacks share width/height/Z/T.
def boolean dimensionsMatch(Collection files) {
    int[] ref = null
    for (File f : files) {
        ImagePlus imp = IJ.openImage(f.getAbsolutePath())
        int[] d = imp.getDimensions()
        imp.close()
        if (ref == null) ref = d
        else if (d[0]!=ref[0] || d[1]!=ref[1] || d[3]!=ref[3] || d[4]!=ref[4]) return false
    }
    return true
}

// Read a series' stored name via Bio-Formats.
def String seriesName(File lif, int s) {
    String n = IJ.runMacro(
        "run('Bio-Formats Macro Extensions');" +
        "Ext.setId('" + lif.getAbsolutePath().replace("\\", "\\\\") + "');" +
        "Ext.setSeries(" + s + ");" +
        "Ext.getSeriesName(name);" +
        "return name;")
    return (n == null) ? "" : n.trim()
}

// Make a string safe for use as a folder/file name.
def String sanitiseName(String name) {
    if (name == null || name == "") return ""
    StringBuilder sb = new StringBuilder()
    for (int i = 0; i < name.length(); i++) {
        String ch = name.substring(i, i + 1)
        sb.append(ch.matches("[A-Za-z0-9_-]") ? ch : "_")
    }
    String safe = sb.toString()
    while (safe.contains("__")) safe = safe.replace("__", "_")
    while (safe.startsWith("_")) safe = safe.substring(1)
    while (safe.endsWith("_"))   safe = safe.substring(0, safe.length() - 1)
    return safe
}


// Close any open images whose title starts with the given prefix.
def closeByTitlePrefix(String prefix) {
    ij.WindowManager.getIDList()?.each { id ->
        def imp = ij.WindowManager.getImage(id)
        if (imp != null && imp.getTitle().startsWith(prefix)) imp.close()
    }
}

// Re-stamp the temporal calibration (frame interval + time unit) onto an
// image. Bio-Formats reads these from the .lif at import, but downstream
// steps (notably Fast4DReg's re-save) drop the frame interval, leaving it at
// 0. We restore it from the value captured at import time. Spatial
// calibration (pixel size / voxel depth) survives processing, so it is left
// untouched here.
def restoreFrameInterval(ImagePlus imp, double frameInterval, String timeUnit) {
    if (imp == null) return
    def cal = imp.getCalibration()
    cal.frameInterval = frameInterval
    if (timeUnit != null && timeUnit != "") cal.setTimeUnit(timeUnit)
    imp.setCalibration(cal)
}

// Bring a Fast4DReg 32-bit float image back to a lower integer depth WITHOUT
// rescaling the data. The trap with ImageJ's converter is that it maps the
// current DISPLAY range onto the target range — so if the display range were
// each channel's own min/max, every channel would be stretched independently
// and the pixel values would change. We avoid that by pinning the display
// range to the target type's FULL range (0..255 for 8-bit, 0..65535 for
// 16-bit) before converting with scaling on: that makes the mapping an
// identity plus rounding (e.g. 162.6 -> 163), clamped to the type. Values
// already sit inside that range (the source was that depth), so nothing is
// clipped. Only down-converts from 32-bit; any other case is left untouched.
def downconvertTo(ImagePlus imp, int targetBitDepth) {
    if (imp == null) return
    if (imp.getBitDepth() != 32) return          // only Fast4DReg's float output
    if (targetBitDepth != 8 && targetBitDepth != 16) return   // 32 (or odd) -> leave as-is

    double hi = (targetBitDepth == 8) ? 255.0 : 65535.0
    imp.setDisplayRange(0.0, hi)                  // fixed full-range -> no per-channel stretch
    ImageConverter.setDoScaling(true)             // map [0,hi] -> type range = identity + round
    boolean isStack = imp.getStackSize() > 1
    if (targetBitDepth == 8) {
        if (isStack) new StackConverter(imp).convertToGray8()
        else         new ImageConverter(imp).convertToGray8()
    } else {
        if (isStack) new StackConverter(imp).convertToGray16()
        else         new ImageConverter(imp).convertToGray16()
    }
}

// =====================================================================
//  METHODS DIARY: assemble a reproducible methods paragraph and save it.
// =====================================================================
def appendMethods(int channels, int sourceBitDepth, boolean convertOutput) {
    String xyzText
    if (doXY && doZ)      xyzText = "lateral (xy) and axial (z)"
    else if (doZ)         xyzText = "axial (z)"
    else                  xyzText = "lateral (xy)"

    methodsLog.append(
        "Individual series were extracted from the Leica .lif file using " +
        "Bio-Formats in Fiji/ImageJ. Each series (a 5D dataset comprising " +
        channels + " channels and a z-stack time series) was separated into " +
        "its constituent channels, each saved as an individual TIFF stack. " +
        "Slow sample drift was corrected using Fast4DReg (v2.1; Pylvanainen " +
        "et al., 2022), which employs NanoJ-Core cross-correlation drift " +
        "estimation (Laine et al., 2019). Drift in the " + xyzText + " " +
        "direction(s) was estimated from channel " + refChannel + " using " +
        projXY + " projections (xy time-averaging = " + timeXY +
        ", maximum expected drift = " + (maxXY == 0 ? "auto" : maxXY) +
        ", reference frame: " + refXY + ")")

    if (doZ) {
        methodsLog.append(
            ", and z-drift from " + projZ + " projections (reslice mode: " +
            resliceMode + ", z time-averaging = " + timeZ +
            ", maximum expected drift = " + (maxZ == 0 ? "auto" : maxZ) +
            ", reference frame: " + refZ + ")")
    }

    methodsLog.append(
        ". The estimated correction was then applied identically to all " +
        channels + " channels so that channel registration was preserved. " +
        "Corrected channels were recombined into a single composite " +
        "hyperstack, and a maximum-intensity projection along the z-axis " +
        "was generated. ")

    if (convertOutput) {
        methodsLog.append(
            "As Fast4DReg performs sub-pixel registration, its outputs are " +
            "32-bit floating point; the corrected images were converted back " +
            "to the original " + sourceBitDepth + "-bit acquisition depth " +
            "without intensity rescaling prior to saving. ")
    } else {
        methodsLog.append(
            "Corrected images were retained as 32-bit floating point, the " +
            "depth produced by Fast4DReg's sub-pixel registration. ")
    }

    methodsLog.append(
        "Both the drift-corrected 5D stack and its maximum-intensity " +
        "projection were saved.")
}

// Write the methods paragraph to a text file in the output base directory.
def writeMethods() {
    if (methodsLog.length() == 0) {
        say("(No methods text generated — no series completed.)")
        return
    }
    say("--- METHODS DRAFT ---")
    dump(methodsLog.toString())
    File methodsFile = new File(outBase, "METHODS_drift_correction.txt")
    methodsFile.text = methodsLog.toString()
    say("Methods text saved to: " + methodsFile.getAbsolutePath())
}


// =====================================================================
//  KICK IT OFF
// =====================================================================
main()