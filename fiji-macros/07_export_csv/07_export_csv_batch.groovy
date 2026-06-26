import fiji.plugin.trackmate.io.TmXmlReader
import fiji.plugin.trackmate.Model
import ij.IJ
import java.io.File
import java.io.PrintWriter

// =====================================================================
//  STAGE 7 — TrackMate XML → CSV batch export  (+ master summary sheets)
//
//  Reads every curated *_MIP.xml in a directory tree and writes two
//  CSV files beside each one:
//
//    *_spots.csv  — one row per spot per frame
//    *_tracks.csv — one row per track (aggregate kinematics)
//
//  THEN concatenates all of them into two MASTER sheets in the chosen
//  root folder (so the whole dataset is analysis-ready in one file each):
//
//    all_spots.csv   — every per-image *_spots.csv, stacked
//    all_tracks.csv  — every per-image *_tracks.csv, stacked
//
//  Each master row is prefixed with a SOURCE_IMAGE column (= parent
//  folder + file base name) so every row can be traced back to — and
//  grouped by — its source image after concatenation.
//
//  Both per-file and master files use the TrackMate four-row header:
//    row 1  ALL_CAPS machine-readable keys   ← use as column names in pandas
//    row 2  human-readable names
//    row 3  short abbreviations
//    row 4  physical dimensions / units
//
//  Recommended pandas read pattern (works for the masters too):
//    df = pd.read_csv(path, header=0, skiprows=[1, 2, 3])
//
//  KEY COLUMN FOR REGION CLASSIFICATION (spots file):
//    MEDIAN_INTENSITY_CH5 → 1 = uninjured, 2 = injured, 3 = injury core
//    (0 = outside tissue). Labels are a SPATIAL GRADIENT, so the median
//    of a boundary-straddling spot resolves to an ADJACENT region rather
//    than jumping across. MEAN_INTENSITY_CH5 matches for spots wholly in
//    one region; MIN==MAX means the spot is cleanly inside one region.
//
//  No image needs to be open — all features were computed during stage 5
//  (settings.addAllAnalyzers()) and are stored inside the XML.
// =====================================================================

// =====================================================================
//  CONFIG
// =====================================================================
def INPUT_DIR    = ""     // leave "" for a folder-picker dialog at runtime
def VISIBLE_ONLY = true   // true  = export spots/tracks that are visible
                          //         (in a track passing all filters)
                          // false = include unlinked singleton detections
                          //         (TRACK_ID will be empty for those)

def WRITE_MASTER       = true             // also write concatenated master sheets?
def MASTER_SPOTS_NAME  = "all_spots.csv"  // master file names, written in the root dir
def MASTER_TRACKS_NAME = "all_tracks.csv"
def SOURCE_COL         = "SOURCE_IMAGE"   // provenance column name in the masters

// =====================================================================
//  RESOLVE INPUT DIRECTORY
// =====================================================================
File inputDir
if (INPUT_DIR?.trim()) {
    inputDir = new File(INPUT_DIR)
} else {
    def dc = new ij.io.DirectoryChooser("Select root folder containing *_MIP.xml files")
    def chosen = dc.getDirectory()
    if (chosen == null) { IJ.log("Export cancelled — no directory chosen."); return }
    inputDir = new File(chosen)
}
if (!inputDir.isDirectory()) {
    IJ.log("ERROR: path is not a directory: " + inputDir.absolutePath); return
}

// =====================================================================
//  DISCOVER FILES  (recursive — mirrors the pattern in stages 4 & 5)
// =====================================================================
def collectXMLs
collectXMLs = { File dir, List<File> acc ->
    dir.listFiles()?.each { f ->
        if (f.isDirectory())
            collectXMLs(f, acc)
        else if (f.name.toLowerCase().endsWith("_mip.xml"))
            acc << f
    }
}

List<File> files = []
collectXMLs(inputDir, files)
files.sort { it.absolutePath }   // sort by full path so subdirs stay grouped

if (files.isEmpty()) {
    IJ.log("No *_MIP.xml files found under: " + inputDir.absolutePath)
    return
}
int total = files.size()

// =====================================================================
//  MASTER SHEET WRITERS  (opened once, before the loop; closed after)
//  Headers are written lazily from the FIRST image so the column set is
//  taken from real data; subsequent images append their rows beneath.
//  (All images come from the same addAllAnalyzers() pipeline, so the
//  feature columns are identical across files.)
// =====================================================================
PrintWriter allSpotsWriter  = null
PrintWriter allTracksWriter = null
if (WRITE_MASTER) {
    allSpotsWriter  = new PrintWriter(new File(inputDir, MASTER_SPOTS_NAME),  "UTF-8")
    allTracksWriter = new PrintWriter(new File(inputDir, MASTER_TRACKS_NAME), "UTF-8")
}
boolean spotsHeaderDone  = false
boolean tracksHeaderDone = false
int masterSpots  = 0
int masterTracks = 0

// =====================================================================
//  BATCH LOOP
// =====================================================================
List<String>        succeeded = []
Map<String, String> failed    = [:]

IJ.log("=" * 68)
IJ.log("TrackMate CSV export  |  " + new Date().format("yyyy-MM-dd HH:mm:ss"))
IJ.log("Input dir : " + inputDir.absolutePath)
IJ.log(String.format("Files     : %d", total))
IJ.log("Master    : " + (WRITE_MASTER ? (MASTER_SPOTS_NAME + " + " + MASTER_TRACKS_NAME) : "off"))
IJ.log("=" * 68)

try {
files.eachWithIndex { file, idx ->

    String label = String.format("[%3d/%d]", idx + 1, total)
    IJ.log("")
    IJ.log(label + "  " + file.name)

    try {
        // ---- load model from XML -----------------------------------------
        //      getModel() triggers XML parsing; check ok AFTER the call.
        def reader = new TmXmlReader(file)
        def model  = reader.getModel()
        if (!reader.isReadingOk())
            throw new RuntimeException("XML parse error: " + reader.getErrorMessage())

        def fm  = model.getFeatureModel()
        def tkm = model.getTrackModel()

        def base = file.absolutePath.replaceAll(/(?i)_MIP\.xml$/, "")
        def spotsPath  = base + "_spots.csv"
        def tracksPath = base + "_tracks.csv"

        // provenance id for the master sheets: parent folder + file base name
        // (e.g. "20250717" + "_" + "20250717_Position001" -> "20250717_20250717_Position001")
        def sourceImage = file.getParentFile().getName() + "_" +
                          file.name.replaceAll(/(?i)_MIP\.xml$/, "")

        // ==================================================================
        //  SPOTS CSV
        // ==================================================================
        def spotFeatKeys   = fm.getSpotFeatures()          // List<String>
        def spotFeatNames  = fm.getSpotFeatureNames()      // Map<String,String>
        def spotFeatShorts = fm.getSpotFeatureShortNames() // Map<String,String>
        def spotFeatDims   = fm.getSpotFeatureDimensions() // Map<String,Dimension>

        // LABEL, ID, TRACK_ID are not in the feature list but belong in the output
        def sCols = ["LABEL", "ID", "TRACK_ID"] + spotFeatKeys

        // Build the four header lines once, so the per-file and master sheets share them.
        def sH1 = sCols.join(",")
        def sH2 = (["Label", "Spot ID", "Track ID"] +
                   spotFeatKeys.collect { spotFeatNames.get(it) ?: it }).join(",")
        def sH3 = (["Label", "Spot ID", "Track ID"] +
                   spotFeatKeys.collect { spotFeatShorts.get(it) ?: it }).join(",")
        def sH4 = (["", "", ""] +
                   spotFeatKeys.collect { spotFeatDims.get(it)?.toString() ?: "" }).join(",")

        def spotLines = []   // accumulated (with SOURCE_IMAGE) for the master, flushed on success

        def sWriter = new PrintWriter(new File(spotsPath), "UTF-8")
        try {
            sWriter.println(sH1); sWriter.println(sH2); sWriter.println(sH3); sWriter.println(sH4)

            int nSpots = 0
            model.getSpots().iterable(VISIBLE_ONLY).each { spot ->
                def trackID = tkm.trackIDOf(spot)
                def row = [spot.getName(), spot.ID(), trackID?.toString() ?: ""] +
                          spotFeatKeys.collect { feat ->
                              def v = spot.getFeature(feat)
                              v != null ? v.toString() : ""
                          }
                def line = row.join(",")
                sWriter.println(line)
                spotLines << (sourceImage + "," + line)
                nSpots++
            }
            IJ.log(String.format("%s      spots  : %d  → %s",
                                 label, nSpots, new File(spotsPath).name))
        } finally {
            sWriter.close()
        }

        // ==================================================================
        //  TRACKS CSV
        //
        //  No region column here — derive region assignment from spots:
        //    region = spots.groupby('TRACK_ID')['MEDIAN_INTENSITY_CH5'].median().round()
        //    (1 = uninjured, 2 = injured, 3 = core)
        // ==================================================================
        def trackFeatKeys   = fm.getTrackFeatures()
        def trackFeatNames  = fm.getTrackFeatureNames()
        def trackFeatShorts = fm.getTrackFeatureShortNames()
        def trackFeatDims   = fm.getTrackFeatureDimensions()

        def tCols = ["LABEL", "TRACK_ID"] + trackFeatKeys

        def tH1 = tCols.join(",")
        def tH2 = (["Label", "Track ID"] +
                   trackFeatKeys.collect { trackFeatNames.get(it) ?: it }).join(",")
        def tH3 = (["Label", "Track ID"] +
                   trackFeatKeys.collect { trackFeatShorts.get(it) ?: it }).join(",")
        def tH4 = (["", ""] +
                   trackFeatKeys.collect { trackFeatDims.get(it)?.toString() ?: "" }).join(",")

        def trackLines = []

        def tWriter = new PrintWriter(new File(tracksPath), "UTF-8")
        try {
            tWriter.println(tH1); tWriter.println(tH2); tWriter.println(tH3); tWriter.println(tH4)

            int nTracks = 0
            tkm.trackIDs(VISIBLE_ONLY).sort().each { trackID ->
                def tName = tkm.name(trackID) ?: ("Track_" + trackID)
                def row = [tName, trackID] +
                          trackFeatKeys.collect { feat ->
                              def v = fm.getTrackFeature(trackID, feat)
                              v != null ? v.toString() : ""
                          }
                def line = row.join(",")
                tWriter.println(line)
                trackLines << (sourceImage + "," + line)
                nTracks++
            }
            IJ.log(String.format("%s      tracks : %d  → %s",
                                 label, nTracks, new File(tracksPath).name))
        } finally {
            tWriter.close()
        }

        // ---- flush this image's rows to the masters (only now that BOTH ---
        //      per-file CSVs wrote cleanly, so a failure can't leave a file
        //      half-represented in the master).
        if (WRITE_MASTER) {
            if (!spotsHeaderDone) {
                allSpotsWriter.println(SOURCE_COL + "," + sH1)
                allSpotsWriter.println("Source Image," + sH2)
                allSpotsWriter.println("Source Image," + sH3)
                allSpotsWriter.println("," + sH4)
                spotsHeaderDone = true
            }
            spotLines.each { allSpotsWriter.println(it); masterSpots++ }

            if (!tracksHeaderDone) {
                allTracksWriter.println(SOURCE_COL + "," + tH1)
                allTracksWriter.println("Source Image," + tH2)
                allTracksWriter.println("Source Image," + tH3)
                allTracksWriter.println("," + tH4)
                tracksHeaderDone = true
            }
            trackLines.each { allTracksWriter.println(it); masterTracks++ }
        }

        succeeded << file.name

    } catch (Exception e) {
        IJ.log(label + "  FAILED: " + e.message)
        failed[file.name] = (e.message ?: e.class.simpleName)
    }
}
} finally {
    // always close the master writers, even if the loop threw unexpectedly
    if (allSpotsWriter  != null) allSpotsWriter.close()
    if (allTracksWriter != null) allTracksWriter.close()
}

// =====================================================================
//  SUMMARY
// =====================================================================
IJ.log("")
IJ.log("=" * 68)
IJ.log("TrackMate CSV export  |  " + new Date().format("yyyy-MM-dd HH:mm:ss"))
IJ.log(String.format("Done      :  %d / %d succeeded", succeeded.size(), total))
if (failed) {
    IJ.log(String.format("Failed    :  %d", failed.size()))
    failed.each { fname, msg ->
        IJ.log("  * " + fname + "  ->  " + msg)
    }
}
if (WRITE_MASTER) {
    IJ.log(String.format("Master    :  %s (%d rows) + %s (%d rows) in %s",
                         MASTER_SPOTS_NAME, masterSpots,
                         MASTER_TRACKS_NAME, masterTracks, inputDir.name))
}
IJ.log("=" * 68)
