# Methods — Stages 3–5: Segmentation, Injury Annotation & Tracking

---

## Stage 3 — Microglia segmentation (`mask_microglia.ijm` / `make_training_classifier.ijm`)

Microglial cell bodies were segmented from the stabilised, maximum-intensity-projected
five-channel stacks using the Trainable Weka Segmentation plugin (v3.3.2; Arganda-Carreras
et al., 2017) in Fiji/ImageJ2. Representative regions of channel 2 (microglia marker) were
manually annotated as foreground (microglia soma) or background using the macro
`make_training_classifier.ijm`; annotations were drawn on images spanning the range of
imaging conditions present in the dataset to maximise classifier generalisability. A random
forest classifier was trained on these pixel-labelled examples and saved as
`microglia.classifier`. The macro `mask_microglia.ijm` applied the stored classifier to
channel 2 of each image in the dataset, thresholded the resulting probability map to produce
a per-frame binary mask, and appended the mask as channel 4 of the multi-channel TIFF stack.
No morphological post-processing or size-based exclusion was applied at this stage; all
segmented objects were retained so that the downstream tracking step could receive the
complete detected population without segmentation-stage bias.

*Reference:* Arganda-Carreras I, Kaynig V, Rueden C, Eliceiri KW, Schindelin J, Cardona A,
Seung HS. Trainable Weka Segmentation: a machine learning tool for microscopy pixel
classification. Bioinformatics. 2017;33(15):2424–2426. doi:10.1093/bioinformatics/btx180

---

## Stage 4 — Injury zone annotation (`draw_injury.ijm`)

To enable spatial stratification of microglial behaviour relative to the injury site, an
anatomical region map was created for each time-lapse using `draw_injury.ijm`. The
experimenter identified a representative reference frame and delineated the fin injury margin
as a closed polygon ROI on channel 1 (anatomy, *mnx:BFP*) using the Fiji ROI tools. The
macro rasterised this ROI into a binary label image in which pixels within the injured zone
were assigned the value 1 and pixels outside were assigned the value 2; the label image was
appended as channel 5 of the stack. Annotators were masked to experimental condition during
this step. Because all TrackMate spot analysers are applied in the subsequent tracking step,
the mean channel 5 intensity of each microglia detection is recorded directly in the exported
XML, allowing individual tracks to be classified as injured-zone or uninjured-zone without
any post-hoc spatial query.

---

## Stage 5 — Cell tracking (`trackmatetracking_batch.groovy`)

Microglial dynamics were quantified using TrackMate v7 (Tinevez et al., 2017; Ershov et al.,
2022) executed as a batch Groovy script in Fiji. For each `*_regions.tif` file in the
processed dataset, the script applied the MaskDetector to channel 4 (binary microglia mask)
with contour simplification enabled; no minimum-quality threshold was imposed, preserving all
segmented objects. Detected spots were linked into tracks using the Advanced Kalman Filter
tracker with the following parameters: maximum initial linking distance 50 µm, Kalman search
radius 75 µm, maximum frame gap 1, gap closing disabled, and track splitting and merging
disabled. The alternative-linking cost factor was set to 1.05 with a cost-percentile cutoff
of 0.9. All built-in TrackMate spot and track analysers were applied, yielding per-detection
mean fluorescence intensities for each channel (including the channel 5 region label),
morphological descriptors (area, circularity, solidity, convexity), and track-level kinematic
statistics (displacement, velocity, confinement ratio). Neither spot-level nor track-level
filters were applied; the complete unfiltered track set was exported as a TrackMate XML file
(`*_tracks.xml`) beside each source image. Tracks were subsequently reviewed and curated
manually in the TrackMate GUI before downstream statistical analysis (Stage 6).

*References:*
Tinevez J-Y, Perry N, Schindelin J, Hoopes GM, Reynolds GD, Laplantine E, Bednarek SY,
Shorte SL, Bhatt DL. TrackMate: An open and extensible platform for single-particle
tracking. Methods. 2017;115:80–90. doi:10.1016/j.ymeth.2016.09.016

Ershov D, Phan M-S, Pylvänäinen JW, Rigaud SU, Le Blanc L, Charles-Orszag A, Conway JRW,
Laine RF, Roy NH, Bonazzi D, Duménil G, Jacquemet G, Tinevez J-Y. TrackMate 7: integrating
state-of-the-art segmentation algorithms into single-object tracking pipelines. Nat Methods.
2022;19(7):829–832. doi:10.1038/s41592-022-01507-1
