import fiji.plugin.trackmate.Model
import fiji.plugin.trackmate.Settings
import fiji.plugin.trackmate.TrackMate
import fiji.plugin.trackmate.Logger
import fiji.plugin.trackmate.SelectionModel
import fiji.plugin.trackmate.detection.MaskDetectorFactory
import fiji.plugin.trackmate.tracking.kalman.AdvancedKalmanTrackerFactory
import fiji.plugin.trackmate.io.TmXmlWriter
import fiji.plugin.trackmate.visualization.hyperstack.HyperStackDisplayer
import fiji.plugin.trackmate.gui.displaysettings.DisplaySettingsIO
import ij.IJ
import java.awt.Color
import java.io.File

// =====================================================================
//  CONFIG
//  Set INPUT_DIR to an absolute path, or leave "" to get a folder
//  picker dialog at runtime.
// =====================================================================
def INPUT_DIR    = ""      // e.g. "C:/data/zebrafish/stabilised"
def MASK_CHANNEL = 4       // ch4 = cleaned binary microglia mask
def SHOW_RESULT  = false   // true → render tracks in GUI (useful for spot-checks)

// Tracker parameters (µm).  DO NOT change without re-tuning on labelled data.
def LINKING_MAX       = 50.0d
def KALMAN_SEARCH     = 75.0d
def GAP_CLOSING_MAX   = 15.0d
def SPLITTING_MAX     = 15.0d
def MERGING_MAX       = 15.0d
def ALT_COST_FACTOR   = 1.05d
def CUTOFF_PERCENTILE = 0.9d
def MAX_FRAME_GAP     = 1

// =====================================================================
//  RESOLVE INPUT DIRECTORY
// =====================================================================
File inputDir
if (INPUT_DIR?.trim()) {
    inputDir = new File(INPUT_DIR)
} else {
    def dc = new ij.io.DirectoryChooser("Select root folder containing *_MIP.tif files")
    def chosen = dc.getDirectory()
    if (chosen == null) { IJ.log("Batch cancelled — no directory chosen."); return }
    inputDir = new File(chosen)
}
if (!inputDir.isDirectory()) {
    IJ.log("ERROR: path is not a directory: " + inputDir.absolutePath); return
}

// =====================================================================
//  DISCOVER FILES  (recursive — descends into subdirectories)
// =====================================================================
//  Uses a self-referencing closure (def x; x = { }) so the closure can
//  call itself by name.  Mirrors the collectMIPs() pattern in 04_draw_injury.ijm.
def collectMIPs
collectMIPs = { File dir, List<File> acc ->
    dir.listFiles()?.each { f ->
        if (f.isDirectory())
            collectMIPs(f, acc)                           // descend
        else if (f.name.toLowerCase().endsWith("_mip.tif"))
            acc << f
    }
}

List<File> files = []
collectMIPs(inputDir, files)
files.sort { it.absolutePath }   // sort by full path so subdirs stay grouped

if (files.isEmpty()) {
    IJ.log("No *_MIP.tif files found under: " + inputDir.absolutePath)
    return
}
int total = files.size()

// =====================================================================
//  BATCH LOOP
// =====================================================================
List<String>        succeeded = []
Map<String, String> failed    = [:]

IJ.log("=" * 68)
IJ.log("TrackMate batch  |  " + new Date().format("yyyy-MM-dd HH:mm:ss"))
IJ.log("Input dir : " + inputDir.absolutePath)
IJ.log(String.format("Files     : %d", total))
IJ.log("=" * 68)

files.eachWithIndex { file, idx ->

    String label = String.format("[%3d/%d]", idx + 1, total)
    IJ.log("")
    IJ.log(label + "  " + file.name)

    def imp = null
    try {
        // ---- open --------------------------------------------------------
        imp = IJ.openImage(file.absolutePath)
        if (imp == null)
            throw new IOException(
                "IJ.openImage returned null — file unreadable or not a valid TIFF")

        // ---- per-image string logger (captured for XML embedding) --------
        //      TrackMate errors also echo to the IJ Log window.
        def logSB = new StringBuilder()
        def imgLogger = new Logger() {
            @Override
            void log(String message, Color color) {
                logSB.append(message).append('\n')
            }
            @Override
            void error(String message) {
                logSB.append("ERROR: ").append(message).append('\n')
                IJ.log("  " + label + " TM: " + message)
            }
            @Override
            void setProgress(double val) { /* no-op in batch */ }
            @Override
            void setStatus(String status) { /* no-op in batch */ }
        }

        // ---- model + settings --------------------------------------------
        def model    = new Model()
        model.setLogger(imgLogger)
        def settings = new Settings(imp)

        // DETECTOR: MaskDetector on ch4 — no parameter changes
        settings.detectorFactory  = new MaskDetectorFactory()
        settings.detectorSettings = [
            'TARGET_CHANNEL'   : (Integer) MASK_CHANNEL,
            'SIMPLIFY_CONTOURS': true,
        ]
        // no spot filters: every mask object is kept

        // TRACKER: Advanced Kalman — no parameter changes
        settings.trackerFactory  = new AdvancedKalmanTrackerFactory()
        settings.trackerSettings = settings.trackerFactory.getDefaultSettings()
        settings.trackerSettings['LINKING_MAX_DISTANCE']            = (Double) LINKING_MAX
        settings.trackerSettings['KALMAN_SEARCH_RADIUS']            = (Double) KALMAN_SEARCH
        settings.trackerSettings['MAX_FRAME_GAP']                   = (Integer) MAX_FRAME_GAP
        settings.trackerSettings['GAP_CLOSING_MAX_DISTANCE']        = (Double) GAP_CLOSING_MAX
        settings.trackerSettings['SPLITTING_MAX_DISTANCE']          = (Double) SPLITTING_MAX
        settings.trackerSettings['MERGING_MAX_DISTANCE']            = (Double) MERGING_MAX
        settings.trackerSettings['ALTERNATIVE_LINKING_COST_FACTOR'] = (Double) ALT_COST_FACTOR
        settings.trackerSettings['CUTOFF_PERCENTILE']               = (Double) CUTOFF_PERCENTILE
        settings.trackerSettings['ALLOW_GAP_CLOSING']               = false
        settings.trackerSettings['ALLOW_TRACK_SPLITTING']           = false
        settings.trackerSettings['ALLOW_TRACK_MERGING']             = false

        // ANALYZERS: all — gives per-channel means (incl. ch5 region label),
        //            morphology (area, circularity, convexity), track kinematics
        settings.addAllAnalyzers()
        // no track filters: complete unfiltered set handed off for manual curation

        // ---- run ---------------------------------------------------------
        def tm = new TrackMate(model, settings)
        if (!tm.checkInput())
            throw new RuntimeException("checkInput failed: " + tm.getErrorMessage())
        if (!tm.process())
            throw new RuntimeException("process failed: "    + tm.getErrorMessage())

        int nSpots  = model.getSpots().getNSpots(true)
        int nTracks = model.getTrackModel().nTracks(true)

        // ---- save XML beside source image --------------------------------
        //      Replaces _MIP.tif suffix → _tracks.xml
        def outPath = file.absolutePath.replaceAll(/(?i)_MIP\.tif$/, "_MIP.xml")
        def outFile = new File(outPath)
        def writer  = new TmXmlWriter(outFile)
        writer.appendLog(logSB.toString())
        writer.appendModel(model)
        writer.appendSettings(settings)
        writer.writeToFile()

        IJ.log(String.format("%s  OK  spots=%-5d  tracks=%-4d  -> %s",
                             label, nSpots, nTracks, outFile.name))
        succeeded << file.name

        // ---- optional display (handy for per-run spot-checks) ------------
        if (SHOW_RESULT) {
            if (!imp.isVisible()) imp.show()
            def sm = new SelectionModel(model)
            def ds = DisplaySettingsIO.readUserDefault()
            def displayer = new HyperStackDisplayer(model, sm, imp, ds)
            displayer.render()
            displayer.refresh()
            // leave image open so the user can inspect it
        }

    } catch (Exception e) {
        IJ.log(label + "  FAILED: " + e.message)
        failed[file.name] = (e.message ?: e.class.simpleName)
    } finally {
        // always close to prevent memory accumulation across large batches;
        // the XML is the handoff artefact — reopen from file for curation
        if (imp != null && !SHOW_RESULT) imp.close()
    }
}

// =====================================================================
//  SUMMARY
// =====================================================================
IJ.log("")
IJ.log("=" * 68)
IJ.log("TrackMate batch  |  " + new Date().format("yyyy-MM-dd HH:mm:ss"))
IJ.log(String.format("Done      :  %d / %d succeeded", succeeded.size(), total))
if (failed) {
    IJ.log(String.format("Failed    :  %d", failed.size()))
    failed.each { fname, msg ->
        IJ.log("  * " + fname + "  ->  " + msg)
    }
}
IJ.log("=" * 68)
