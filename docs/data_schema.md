# TrackMate CSV Schema

Reference for the two CSV exports produced by `05_track/trackmatetracking_batch.groovy`
and consumed by the Python analysis stages (8–9).

---

## Header structure (both files)

TrackMate writes **four header rows** before the data.

| Row | Content |
|-----|---------|
| 1 | `ALL_CAPS` machine-readable column names — **use these as column names** |
| 2 | Human-readable names |
| 3 | Short abbreviations |
| 4 | Units |

**Recommended pandas read pattern:**

```python
df = pd.read_csv(path, header=0, skiprows=[1, 2, 3])
```

To capture units for axis labels:

```python
units = pd.read_csv(path, header=None, skiprows=3, nrows=1).iloc[0].tolist()
```

---

## `*_spots.csv` — one row per detection per frame

### Identity & position

| Column | Unit | Notes |
|--------|------|-------|
| `LABEL` | — | e.g. `ID2114` |
| `ID` | — | Unique spot integer ID |
| `TRACK_ID` | — | Foreign key → `*_tracks.csv` |
| `POSITION_X` / `_Y` / `_Z` | µm | Z = 0 for MIP data |
| `POSITION_T` | sec | Absolute time; frame interval ≈ 2 400 s (40 min) in example data |
| `FRAME` | — | 0-indexed |

### Per-channel intensities

Columns exist for each channel present in the source image:
`MEAN_INTENSITY_CH{n}`, `MEDIAN_INTENSITY_CH{n}`, `MIN_INTENSITY_CH{n}`,
`MAX_INTENSITY_CH{n}`, `TOTAL_INTENSITY_CH{n}`, `STD_INTENSITY_CH{n}`.

| Channel | Content | Notes |
|---------|---------|-------|
| CH1 | Anatomy (*mnx:BFP*) | |
| CH2 | Microglia marker | Primary signal for motility |
| CH3 | Neuron trace | |
| CH4 | Binary microglia mask | Present only in `*_regions.tif` runs |
| CH5 | Region label | Present only in `*_regions.tif` runs; **injured = 1, uninjured = 2** |

> **Note on example file (`examplespots.csv`):** This was exported from a 3-channel image
> (pre-region pipeline). CH4 and CH5 columns are absent. All morphology columns are
> placeholders — see below.

### Morphology

| Column | Unit | Notes |
|--------|------|-------|
| `AREA` | µm² | Real contour area when MaskDetector is used on CH4; **= π × 5² = 78.54 for all spots in the example file** (circular placeholder — do not use) |
| `PERIMETER` | µm | Same caveat |
| `CIRCULARITY` | — | 1.0 = perfect circle; real values < 1 with MaskDetector |
| `SOLIDITY` | — | Area / convex hull area |
| `SHAPE_INDEX` | — | Perimeter / √Area; dimensionless compactness |
| `ELLIPSE_*` | µm / rad | Fitted ellipse parameters; all `(5, 5, 0)` in example file |

Morphology columns will contain meaningful per-cell values once the pipeline is run on
the full 5-channel `*_regions.tif` stacks with the MaskDetector on CH4.

### Contrast / SNR

`CONTRAST_CH{n}`, `SNR_CH{n}` — signal contrast and signal-to-noise ratio per channel.
Useful for QC filtering but not primary analysis variables.

---

## `*_tracks.csv` — one row per track (aggregated)

| Column | Unit | Notes |
|--------|------|-------|
| `LABEL` | — | e.g. `Track_0` |
| `TRACK_ID` | — | Primary key; matches `TRACK_ID` in spots file |
| `NUMBER_SPOTS` | — | Total detections in track |
| `NUMBER_GAPS` | — | Frames where cell was undetected mid-track |
| `TRACK_DURATION` | sec | `TRACK_STOP − TRACK_START` |
| `TRACK_DISPLACEMENT` | µm | Net displacement start → end |
| `TOTAL_DISTANCE_TRAVELED` | µm | Summed inter-frame step lengths |
| `CONFINEMENT_RATIO` | — | `TRACK_DISPLACEMENT / TOTAL_DISTANCE_TRAVELED`; 1 = straight line, 0 = confined |
| `TRACK_MEAN_SPEED` | µm/sec | Mean of per-step speeds |
| `TRACK_MAX_SPEED` | µm/sec | |
| `MEAN_DIRECTIONAL_CHANGE_RATE` | rad/sec | Mean angular change between steps |
| `LINEARITY_OF_FORWARD_PROGRESSION` | — | Correlation of displacement with time |

> **No region column in this file.** Injured / uninjured classification must be derived
> from spot-level `MEAN_INTENSITY_CH5` (= 1 or 2 per spot) and then aggregated to
> track level — e.g. majority vote or mean rounding.

---

## Joining spots → tracks

```python
spots  = pd.read_csv("*_spots.csv",  header=0, skiprows=[1, 2, 3])
tracks = pd.read_csv("*_tracks.csv", header=0, skiprows=[1, 2, 3])

merged = spots.merge(tracks, on="TRACK_ID", suffixes=("_spot", "_track"))
```
