import fiji.plugin.trackmate.io.TmXmlReader
import fiji.plugin.trackmate.Model
import ij.IJ
import java.io.File
import java.io.PrintWriter

// =====================================================================
//  STAGE 7 — TrackMate XML → CSV batch export
//
//  Reads every curated *_tracks.xml in a directory tree and writes two
//  CSV files beside each one:
//
//    *_spots.csv  — one row per spot per frame
//    *_tracks.csv — one row per track (aggregate kinematics)
//
//  Both files use the TrackMate four-row header convention:
//    row 1  ALL_CAPS machine-readable keys   ← use as column names in pandas
//    row 2  human-readable names
//    row 3  short abbreviations
//    row 4  physical dimensions / units
//
//  Recommended pandas read pattern:
//    df = pd.read_csv(path, header=0, skiprows=[1, 2, 3])
//
//  KEY COLUMN FOR REGION CLASSIFICATION (spots file):
//    MEDIAN_INTENSITY_CH5  → 1.0 = injured zone, 2.0 = uninjured zone
//    Median is preferred over mean: for spots that straddle the injury
//    boundary, median snaps to whichever side holds the majority of pixels.
//    MEAN_INTENSITY_CH5 is identical for spots entirely inside one region.
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

// =====================================================================
//  RESOLVE INPUT DIRECTORY
// =====================================================================
File inputDir
if (INPUT_DIR?.trim()) {
    inputDir = new File(INPUT_DIR)
} else {
    def dc = new ij.io.DirectoryChooser("Select root folder containing *_tracks.xml files")
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
//  BATCH LOOP
// =====================================================================
List<String>        succeeded = []
Map<String, String> failed    = [:]

IJ.log("=" * 68)
IJ.log("TrackMate CSV export  |  " + new Date().format("yyyy-MM-dd HH:mm:ss"))
IJ.log("Input dir : " + inputDir.absolutePath)
IJ.log(String.format("Files     : %d", total))
IJ.log("=" * 68)

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

        // ==================================================================
        //  SPOTS CSV
        // ==================================================================
        def spotFeatKeys   = fm.getSpotFeatures()          // List<String>
        def spotFeatNames  = fm.getSpotFeatureNames()      // Map<String,String>
        def spotFeatShorts = fm.getSpotFeatureShortNames() // Map<String,String>
        def spotFeatDims   = fm.getSpotFeatureDimensions() // Map<String,Dimension>

        // LABEL, ID, TRACK_ID are not in the feature list but belong in the output
        def sCols = ["LABEL", "ID", "TRACK_ID"] + spotFeatKeys

        def sWriter = new PrintWriter(new File(spotsPath), "UTF-8")
        try {
            // Row 1 — machine-readable keys (use these as pandas column names)
            sWriter.println(sCols.join(","))
            // Row 2 — human-readable names
            sWriter.println((["Label", "Spot ID", "Track ID"] +
                              spotFeatKeys.collect { spotFeatNames.get(it) ?: it }).join(","))
            // Row 3 — short names / abbreviations
            sWriter.println((["Label", "Spot ID", "Track ID"] +
                              spotFeatKeys.collect { spotFeatShorts.get(it) ?: it }).join(","))
            // Row 4 — physical dimensions / units
            sWriter.println((["", "", ""] +
                              spotFeatKeys.collect { spotFeatDims.get(it)?.toString() ?: "" }).join(","))

            // Data rows
            int nSpots = 0
            model.getSpots().iterable(VISIBLE_ONLY).each { spot ->
                def trackID = tkm.trackIDOf(spot)
                def row = [spot.getName(), spot.ID(), trackID?.toString() ?: ""] +
                          spotFeatKeys.collect { feat ->
                              def v = spot.getFeature(feat)
                              v != null ? v.toString() : ""
                          }
                sWriter.println(row.join(","))
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
        //    (1 = injured, 2 = uninjured)
        // ==================================================================
        def trackFeatKeys   = fm.getTrackFeatures()
        def trackFeatNames  = fm.getTrackFeatureNames()
        def trackFeatShorts = fm.getTrackFeatureShortNames()
        def trackFeatDims   = fm.getTrackFeatureDimensions()

        def tCols = ["LABEL", "TRACK_ID"] + trackFeatKeys

        def tWriter = new PrintWriter(new File(tracksPath), "UTF-8")
        try {
            // Row 1 — machine-readable keys
            tWriter.println(tCols.join(","))
            // Row 2 — human-readable names
            tWriter.println((["Label", "Track ID"] +
                              trackFeatKeys.collect { trackFeatNames.get(it) ?: it }).join(","))
            // Row 3 — short names
            tWriter.println((["Label", "Track ID"] +
                              trackFeatKeys.collect { trackFeatShorts.get(it) ?: it }).join(","))
            // Row 4 — dimensions
            tWriter.println((["", ""] +
                              trackFeatKeys.collect { trackFeatDims.get(it)?.toString() ?: "" }).join(","))

            // Data rows — sorted by track ID for reproducible output order
            int nTracks = 0
            tkm.trackIDs(VISIBLE_ONLY).sort().each { trackID ->
                def tName = tkm.name(trackID) ?: ("Track_" + trackID)
                def row = [tName, trackID] +
                          trackFeatKeys.collect { feat ->
                              def v = fm.getTrackFeature(trackID, feat)
                              v != null ? v.toString() : ""
                          }
                tWriter.println(row.join(","))
                nTracks++
            }
            IJ.log(String.format("%s      tracks : %d  → %s",
                                 label, nTracks, new File(tracksPath).name))
        } finally {
            tWriter.close()
        }

        succeeded << file.name

    } catch (Exception e) {
        IJ.log(label + "  FAILED: " + e.message)
        failed[file.name] = (e.message ?: e.class.simpleName)
    }
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
IJ.log("=" * 68)
