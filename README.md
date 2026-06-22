# Microglia Motility Pipeline

Fiji/ImageJ + Python pipeline for quantifying microglia motility in zebrafish
spinal cord injury timelapses. Takes raw Leica `.lif` files to drift-corrected
stacks, automated segmentation, region annotation, cell tracking, and motility
graphs.

**Status:** Stages 1–4 complete and tested. Stages 5–9 in progress (see the
pipeline overview below).

---

## Channel layout

The pipeline assumes (and builds up) the following channel order. Several
scripts depend on this, so it's the single most important convention to keep
consistent:

| Channel | Content | Added by |
|---------|---------|----------|
| 1 | Anatomy marker (mnxbfp) — used to locate the tissue body | acquisition |
| 2 | Microglia marker — what the Labkit classifier is trained on | acquisition |
| 3 | Neuron trace (dye uptake) | acquisition |
| 4 | Microglia binary mask — detected by TrackMate | Step 03 |
| 5 | Region label map (injured / uninjured) | Step 04 |

---

## Pipeline overview

```
Raw .lif
   │
   ▼
01  Ingest & stabilise        draft_v7.groovy
    ├─ Extract series from .lif (Bio-Formats)
    ├─ Drift-correct XY+Z (Fast4DReg)
    └─ Max-intensity Z-projection → corrected 5D stack + MIP .tif
   │
   ▼  [QC]  make_ortho_maxproject.ijm
            (orthogonal cross-view of the active stack, to inspect
             stabilisation; scrub through time as a movie)
   │
   ▼
03  Segment microglia         mask_microglia.ijm
    ├─ Extract the microglia marker channel (default ch2)
    ├─ Classify with trained Labkit model
    └─ Clean mask → append as a new channel → *_withMask.tif
   │
   ▼
04  Annotate injury region    draw_injury.ijm
    ├─ Standardise orientation (head left, injury top) — records
    │  any flips in the filename (_FH / _FV)
    ├─ Auto-threshold tissue body (anatomy channel)
    ├─ User draws the injury boundary line
    └─ Region map (injured=1, uninjured=2) → new channel → *_regions.tif
   │
   ▼
05  Track microglia           trackmatetracking.groovy   [single-image; batch TODO]
    ├─ MaskDetector on the mask channel (ch4)
    ├─ Advanced Kalman tracker
    └─ Save *_tracks.xml for curation
   │
   ▼  [Manual QC — TrackMate GUI]
       Review tracks; fix errors directly, or delete all and place spots
       manually per timepoint. Re-export XML when satisfied.
   │
   ▼
07  Export measurements       [TODO]
    └─ CSV: spot positions, track IDs, distances, region labels
   │
   ▼
08  Aggregate data            python/aggregate/  [TODO]
    └─ Combine CSVs across experiments/conditions
   │
   ▼
09  Graphs                    python/plots/  [TODO]
    └─ Motility metrics by region, condition, timepoint
```

---

## Requirements

### Fiji plugins
Install via **Help › Update › Manage update sites**:

| Plugin | Update site | Used in |
|--------|-------------|---------|
| Bio-Formats | (bundled) | Step 01 |
| Fast4DReg | `Fast4DReg` | Step 01 |
| Labkit | `Labkit` | Step 03 |
| MorphoLibJ | `IJPB-plugins` | Step 04 (Keep Largest Region) |
| TrackMate | (bundled) | Step 05 |

### Python
<!-- TODO: add requirements.txt once Python scripts are written -->

---

## Usage

### Step 01 — Ingest & stabilise (`draft_v7.groovy`)

Run via **Plugins › Macros › Run…** or drag onto Fiji.

A dialog asks for:
- Input `.lif` file
- Output base directory
- Reference channel for drift estimation (default: channel 1)
- Number of series to process (0 = all)
- XY/Z drift correction toggles and parameters

Outputs (per series, in a subfolder named after the series):
- `<series>_corrected_xyz.tif` — drift-corrected 5D stack
- `<series>_corrected_xyz_MIP.tif` — max-intensity Z-projection
- `RUN_LOG_<timestamp>.txt` — full processing log
- `METHODS_drift_correction.txt` — auto-generated methods paragraph

<!-- TODO: add screenshot of dialog -->
<!-- TODO: add screenshot of example output -->

---

### QC — Stabilisation check (`make_ortho_maxproject.ijm`)

Select a stabilised stack as the active image, then run the script. It builds
a single orthogonal cross-view (XY top-left, YZ top-right, XZ bottom) from
max-intensity projections, preserving the time axis so the result can be
scrubbed/played as a movie to inspect whether drift correction worked.

<!-- TODO: add screenshot of example cross-view -->

---

### Step 03 — Segment microglia (`mask_microglia.ijm`)

**One-time setup:** train the Labkit classifier. `make_training_classifier.ijm`
builds a time-aligned montage of the microglia marker channel across all your
datasets; annotate that montage in Labkit and save the resulting `.classifier`
file. (See `fiji-macros/03_segment/`.)

**Segmentation:**
1. Open the MIP image(s) you want to process in Fiji
2. Run `mask_microglia.ijm`
3. In the launch dialog, choose **Active image only** or **All open images**,
   and confirm/browse to the `.classifier` file
4. Each image produces `<name>_withMask.tif`, with the cleaned binary mask
   appended as a new channel (channel 4 for a standard 3-channel input)

Key parameters (edit at top of script):
- `DEFAULT_CLASSIFIER` — optional path to pre-fill the classifier field (leave
  `""` to browse each time)
- `CHANNEL_TO_KEEP` — which channel the classifier was trained on (default: 2)
- `MIN_AREA` — minimum object size in pixels (default: 800)
- `MEDIAN_RADIUS` — smoothing radius after area opening (default: 2)

<!-- TODO: add screenshot of mask overlay -->

---

### Step 04 — Annotate injury region (`draw_injury.ijm`)

Run on one `_withMask.tif` at a time (interactive step).

1. **Standardise orientation.** A dialog shows the target (head left, injury
   top) and asks which way the head currently points (read from the anatomy
   channel) and which side the injury is on. The script flips the stack as
   needed and records what it did in the output name: `_FH` (flipped
   horizontally, head was on the right) and/or `_FV` (flipped vertically,
   injury was on the bottom), in `_FH_FV` order.
2. **Draw the boundary.** With the line tool, draw a straight line across the
   full tissue width (overshoot slightly), then click OK.
3. The script auto-thresholds the tissue body from the anatomy channel, cuts it
   at your line, and appends a region label map as a new channel
   (injured = 1, uninjured = 2). Because orientation is standardised first,
   injured is always the top region.

Output: `<name>[_FH][_FV]_regions.tif` with a cyan overlay showing the tissue
outline and the cut line.

Key parameters (edit at top of script):
- `TARGET_HEAD` / `TARGET_INJURY` — the orientation convention (default: left / top)
- `TISSUE_CHANNEL` — anatomy channel to threshold (default: 1)
- `BLUR_SIGMA`, `THRESHOLD_METHOD` — tissue-body detection tuning

<!-- TODO: add screenshot of orientation dialog -->
<!-- TODO: add screenshot of line drawing + final overlay -->

---

### Step 05 — Track microglia (`trackmatetracking.groovy`)

> **Note:** currently a single-image script with a hardcoded input path.
> Batch conversion (loop over a folder of `*_regions.tif`) is the next build.

For the given image it:
- Detects microglia from the binary mask (channel 4)
- Tracks using the Advanced Kalman tracker (gap closing / splitting / merging
  all disabled, for clean independent tracks)
- Adds all analyzers, so the region label (ch5) is captured per spot
- Saves `*_tracks.xml` alongside the image for manual curation

Key tracker parameters (edit at top of script):
- `LINKING_MAX` — max linking distance in µm (default: 50)
- `KALMAN_SEARCH` — Kalman search radius in µm (default: 75)
- `GAP_CLOSING_MAX` — max gap-closing distance in µm (default: 15)
- `MAX_FRAME_GAP` — max frame gap for gap closing (default: 1)

---

### Step 06 — Manual track QC (TrackMate GUI)

Open each `*_tracks.xml` in TrackMate (**Plugins › TrackMate**, then load XML).

Two modes depending on track quality:
- **Minor errors:** edit individual tracks directly in the TrackMate GUI
- **Poor tracking:** delete all tracks, switch to manual mode, and place spots
  over microglia frame by frame

Re-export the curated XML when satisfied.

---

### Step 07 — Export measurements

<!-- TODO -->

---

### Step 08 — Aggregate data

<!-- TODO -->

---

### Step 09 — Graphs

<!-- TODO -->

---

## Methods

<!-- Auto-generated methods text for step 01 is written to
     METHODS_drift_correction.txt in the output folder after each run.
     Methods for steps 03–05 will be added here once scripts are finalised. -->

### Drift correction (Step 01)
*See `METHODS_drift_correction.txt` generated in your output folder.*

### Segmentation (Step 03)
<!-- TODO -->

### Region annotation (Step 04)
<!-- TODO -->

### Tracking (Step 05)
<!-- TODO -->

---

## Repository structure

```
microglia-motility-pipeline/
├── README.md
├── .gitignore
├── fiji-macros/
│   ├── 01_ingest_stabilise/
│   │   └── draft_v7.groovy
│   ├── 02_qc/
│   │   └── make_ortho_maxproject.ijm
│   ├── 03_segment/
│   │   ├── make_training_classifier.ijm   (one-time utility: build training montage)
│   │   ├── mask_microglia.ijm             (single image or batch, chosen at launch)
│   │   └── microglia.classifier           (trained Labkit model)
│   ├── 04_annotate_injury/
│   │   └── draw_injury.ijm
│   └── 05_track/
│       └── trackmatetracking.groovy
├── python/
│   ├── aggregate/
│   └── plots/
└── docs/
    └── screenshots/
```

> **Note on large files:** the Labkit training montage (a large `.tif`) is not
> committed — it is regenerated from source data by `make_training_classifier.ijm`.
> The trained `microglia.classifier` (small) *is* committed for reproducibility.
> See `.gitignore`.

---

## Authors

<!-- TODO: add your name, affiliation, contact -->

## Acknowledgements

- [Fast4DReg](https://github.com/guijacquemet/Fast4DReg) — Pylvänäinen et al. 2022, doi:10.1242/jcs.260728
- [NanoJ-Core](https://github.com/HenriquesLab/NanoJ-Core) — Laine et al. 2019, doi:10.1088/1361-6463/ab0261
- [Labkit](https://imagej.net/plugins/labkit/) — Arzt et al. 2022, doi:10.3389/fcomp.2022.777728
- [MorphoLibJ](https://imagej.net/plugins/morpholibj) — Legland et al. 2016, doi:10.1093/bioinformatics/btw413
- [TrackMate](https://imagej.net/plugins/trackmate/) — Tinevez et al. 2017, doi:10.1016/j.ymeth.2016.09.016
