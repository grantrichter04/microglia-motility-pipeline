import fiji.plugin.trackmate.Model
import fiji.plugin.trackmate.Settings
import fiji.plugin.trackmate.TrackMate
import fiji.plugin.trackmate.Logger
import fiji.plugin.trackmate.SelectionModel
import fiji.plugin.trackmate.detection.MaskDetectorFactory
import fiji.plugin.trackmate.tracking.kalman.AdvancedKalmanTrackerFactory
import fiji.plugin.trackmate.io.TmXmlWriter
import fiji.plugin.trackmate.features.FeatureFilter
import fiji.plugin.trackmate.visualization.hyperstack.HyperStackDisplayer
import ij.IJ
import java.io.File

// =====================================================================
//  CONFIG — single image test
// =====================================================================
def IMAGE_PATH = "C:\\Users\\MQ10002204\\Macquarie University\\Morsch Group - Documents\\Nida\\Timelapses Fin injury\\Working_directory\\stabilised\\20251017_20251017_Position005-good\\20251017_20251017_Position005-good_corrected_xyz_MIP_withMask.tif_regions.tif"
def MASK_CHANNEL = 4        // detect on the cleaned mask channel
def SHOW_RESULT  = true     // display tracks in the GUI for eyeballing

// tracker params (from your saved settings) -- all distances in microns
def LINKING_MAX        = 50.0d
def KALMAN_SEARCH      = 75.0d
def GAP_CLOSING_MAX    = 15.0d
def SPLITTING_MAX      = 15.0d
def MERGING_MAX        = 15.0d
def ALT_COST_FACTOR    = 1.05d
def CUTOFF_PERCENTILE  = 0.9d
def MAX_FRAME_GAP = 1

// =====================================================================
def imp = IJ.openImage(IMAGE_PATH)
if (imp == null) { IJ.log("Could not open: " + IMAGE_PATH); return }
imp.show()   // helps display + ensures calibration is read

def model = new Model()
model.setLogger(Logger.IJ_LOGGER)

def settings = new Settings(imp)

// ---- DETECTOR: mask detector on channel 4 ----
settings.detectorFactory = new MaskDetectorFactory()
settings.detectorSettings = [
    'TARGET_CHANNEL'    : (Integer) MASK_CHANNEL,
    'SIMPLIFY_CONTOURS' : true,
]

// ---- NO spot filters: keep every detected mask ----
// (leave settings.spotFilters empty)

// ---- TRACKER: Advanced Kalman ----
settings.trackerFactory  = new AdvancedKalmanTrackerFactory()
settings.trackerSettings = settings.trackerFactory.getDefaultSettings()
settings.trackerSettings['LINKING_MAX_DISTANCE']            = (Double) LINKING_MAX
settings.trackerSettings['KALMAN_SEARCH_RADIUS']           = (Double) KALMAN_SEARCH
settings.trackerSettings['MAX_FRAME_GAP']                  = (Integer) MAX_FRAME_GAP
settings.trackerSettings['GAP_CLOSING_MAX_DISTANCE']        = (Double) GAP_CLOSING_MAX
settings.trackerSettings['SPLITTING_MAX_DISTANCE']          = (Double) SPLITTING_MAX
settings.trackerSettings['MERGING_MAX_DISTANCE']           = (Double) MERGING_MAX
settings.trackerSettings['ALTERNATIVE_LINKING_COST_FACTOR'] = (Double) ALT_COST_FACTOR
settings.trackerSettings['CUTOFF_PERCENTILE']             = (Double) CUTOFF_PERCENTILE
settings.trackerSettings['ALLOW_GAP_CLOSING']             = false
settings.trackerSettings['ALLOW_TRACK_SPLITTING']         = false
settings.trackerSettings['ALLOW_TRACK_MERGING']          = false

// ---- analyzers: add all so every spot gets per-channel features (incl. ch5) ----
settings.addAllAnalyzers()

// ---- NO track filters: keep every track ----
// (leave settings.trackFilters empty)

// =====================================================================
def trackmate = new TrackMate(model, settings)
if (!trackmate.checkInput() || !trackmate.process()) {
    IJ.log("TrackMate failed: " + trackmate.getErrorMessage())
    return
}
IJ.log("Spots: " + model.getSpots().getNSpots(true) +
       "   Tracks: " + model.getTrackModel().nTracks(true))

// ---- save XML beside the image (handoff for manual curation) ----
def outFile = new File(IMAGE_PATH.replaceAll(/(?i)\.tif$/, "_tracks.xml"))
def writer = new TmXmlWriter(outFile)
writer.appendLog(Logger.IJ_LOGGER.toString())
writer.appendModel(model)
writer.appendSettings(settings)
writer.writeToFile()
IJ.log("Saved: " + outFile)

// ---- optionally display ----
if (SHOW_RESULT) {
    def sm = new SelectionModel(model)
    def ds = fiji.plugin.trackmate.gui.displaysettings.DisplaySettingsIO.readUserDefault()
    def displayer = new HyperStackDisplayer(model, sm, imp, ds)
    displayer.render()
    displayer.refresh()
}