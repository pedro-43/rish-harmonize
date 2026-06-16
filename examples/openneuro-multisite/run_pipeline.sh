#!/bin/bash
# ==========================================================================
# OpenNeuro ds000206 multi-site RISH harmonization — full signal-level pipeline
#
# Traveling-subject design (same subjects at every site). MRtrix3-only:
# registration via population_template (mrregister under the hood) — no ANTs.
#
# Steps:
#   1. Prepare    — convert DWI->MIF, brain mask, FA map (per session)
#   2. RISH       — extract native per-shell RISH (consistent lmax)
#   3. Template   — build FA population template + per-session warps
#   4. Warp       — warp RISH + masks to template space; build group mask
#   5. Manifest   — write RISH-GLM manifest.csv
#   6. GLM        — rish-glm (signal_rish) -> per-site scale maps
#   7. SiteEffect — permutation test of site effect, pre vs post harmonization
#   8. QC         — qc-report figures
#
# Usage: ./run_pipeline.sh [step]
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
mkdir -p "$OUT"
STEP="${1:-all}"
run() { [[ "$STEP" == "all" || "$STEP" == "$1" ]]; }
hr() { echo ""; echo "================================================================"; echo "  $1"; echo "================================================================"; }

# --------------------------------------------------------------------------
# Step 1: Prepare — convert, mask, FA
# --------------------------------------------------------------------------
if run 1; then
hr "Step 1: Prepare (convert DWI->MIF, mask, FA)"
for SUBJ in "${SUBJECTS[@]}"; do
  for SITE in "${SITES[@]}"; do
    PREP="$OUT/prep/$SUBJ/$SITE"; mkdir -p "$PREP"
    [[ -f "$PREP/fa.mif" ]] && { echo "  [$SUBJ/$SITE] done, skip"; continue; }
    BASE=$(dwi_base "$SUBJ" "$SITE") || { echo "  [$SUBJ/$SITE] no data, skip"; continue; }
    mrconvert "$BASE.nii.gz" -fslgrad "$BASE.bvec" "$BASE.bval" \
        "$PREP/dwi.mif" -force -quiet -nthreads "$NTHREADS"
    dwi2mask "$PREP/dwi.mif" "$PREP/mask.mif" -force -quiet -nthreads "$NTHREADS"
    dwi2tensor "$PREP/dwi.mif" -mask "$PREP/mask.mif" "$PREP/dt.mif" -force -quiet -nthreads "$NTHREADS"
    tensor2metric "$PREP/dt.mif" -fa "$PREP/fa.mif" -mask "$PREP/mask.mif" -force -quiet
    rm -f "$PREP/dt.mif"
    echo "  [$SUBJ/$SITE] prepared"
  done
done
fi

# --------------------------------------------------------------------------
# Step 2: Extract native RISH (consistent lmax across all sessions)
# --------------------------------------------------------------------------
if run 2; then
hr "Step 2: Extract native RISH"
DWI_LIST="$OUT/all_dwis.txt"; > "$DWI_LIST"
for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
  echo "$OUT/prep/$SUBJ/$SITE/dwi.mif" >> "$DWI_LIST"
done; done
echo "  DWI list: $(wc -l < "$DWI_LIST") sessions"
for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
  RDIR="$OUT/native_rish/$SUBJ/$SITE"
  [[ -f "$RDIR/shell_meta.json" ]] && { echo "  [$SUBJ/$SITE] skip"; continue; }
  rish-harmonize extract-native-rish "$OUT/prep/$SUBJ/$SITE/dwi.mif" \
      -o "$RDIR" --mask "$OUT/prep/$SUBJ/$SITE/mask.mif" \
      --consistent-with "$DWI_LIST" --threads "$NTHREADS"
  echo "  [$SUBJ/$SITE] RISH extracted"
done; done
fi

# --------------------------------------------------------------------------
# Step 3: Build FA population template + per-session warps
# --------------------------------------------------------------------------
if run 3; then
hr "Step 3: Build FA population template (population_template)"
FADIR="$OUT/template/fa_inputs"; MASKDIR="$OUT/template/mask_inputs"
WARPDIR="$OUT/template/warps"
mkdir -p "$FADIR" "$MASKDIR" "$WARPDIR"
for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
  # guard instead of `cp -n`: BSD/macOS `cp -n` exits non-zero when the
  # destination exists, which would trip `set -e` on reruns.
  [[ -f "$FADIR/${SUBJ}_${SITE}.mif" ]]   || cp "$OUT/prep/$SUBJ/$SITE/fa.mif"   "$FADIR/${SUBJ}_${SITE}.mif"
  [[ -f "$MASKDIR/${SUBJ}_${SITE}.mif" ]] || cp "$OUT/prep/$SUBJ/$SITE/mask.mif" "$MASKDIR/${SUBJ}_${SITE}.mif"
done; done
if [[ -f "$OUT/template/fa_template.mif" ]]; then
  echo "  template exists, skip"
else
  # Short, *matched* nonlinear schedule (nl_scales and nl_niter must be the
  # same length) keeps this demo fast; lengthen for production-quality warps.
  population_template "$FADIR" "$OUT/template/fa_template.mif" \
      -mask_dir "$MASKDIR" -warp_dir "$WARPDIR" \
      -type rigid_affine_nonlinear \
      -nl_scale 0.5,0.75,1.0 -nl_niter 5,5,5 \
      -nthreads "$NTHREADS" -force
fi
echo "  template + warps ready"
fi

# --------------------------------------------------------------------------
# Step 4: Warp RISH + masks to template space; build group mask
# --------------------------------------------------------------------------
if run 4; then
hr "Step 4: Warp RISH to template space + group mask"
WARPDIR="$OUT/template/warps"
TGRID="$OUT/template/fa_template.mif"
MASK_ARGS=()
for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
  WARP="$WARPDIR/${SUBJ}_${SITE}.mif"
  for BDIR in "$OUT/native_rish/$SUBJ/$SITE"/b*/; do
    BVAL=$(basename "$BDIR")
    TDIR="$OUT/template_rish/$SUBJ/$SITE/$BVAL/rish"; mkdir -p "$TDIR"
    for R in "$BDIR/rish"/rish_l*.mif; do
      OUTF="$TDIR/$(basename "$R")"
      [[ -f "$OUTF" ]] && continue
      # population_template emits 5D "warpfull" files -> use -warp_full.
      # Default direction (image1->image2) maps subject -> template.
      mrtransform "$R" -warp_full "$WARP" -template "$TGRID" -interp linear "$OUTF" -force -quiet
    done
  done
  # warp this session's mask to template for the group mask
  TM="$OUT/template/mask_warped/${SUBJ}_${SITE}.mif"; mkdir -p "$(dirname "$TM")"
  [[ -f "$TM" ]] || mrtransform "$OUT/prep/$SUBJ/$SITE/mask.mif" -warp_full "$WARP" \
      -template "$TGRID" -interp nearest "$TM" -force -quiet
  MASK_ARGS+=("$TM")
  echo "  [$SUBJ/$SITE] warped"
done; done
mrmath "${MASK_ARGS[@]}" min "$OUT/template/group_mask.mif" -force -quiet
NV=$(mrstats "$OUT/template/group_mask.mif" -output count -ignorezero 2>/dev/null | tr -d ' ')
echo "  group mask: $NV voxels"
fi

# --------------------------------------------------------------------------
# Step 5: RISH-GLM manifest (subject, site, rish_dir)
# --------------------------------------------------------------------------
if run 5; then
hr "Step 5: Write manifest.csv"
MAN="$OUT/manifest.csv"
echo "subject,site,rish_dir" > "$MAN"
for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
  echo "${SUBJ}_${SITE},${SITE},$OUT/template_rish/$SUBJ/$SITE/" >> "$MAN"
done; done
echo "  manifest: $MAN ($(($(wc -l < "$MAN")-1)) rows)"
fi

# --------------------------------------------------------------------------
# Step 6: RISH-GLM -> per-site scale maps
# --------------------------------------------------------------------------
if run 6; then
hr "Step 6: RISH-GLM (signal_rish)"
rish-harmonize rish-glm \
    --manifest "$OUT/manifest.csv" \
    --reference-site "$REF_SITE" \
    --mask "$OUT/template/group_mask.mif" \
    -o "$OUT/glm_output" \
    --threads "$NTHREADS"
echo "  GLM done; scale maps in $OUT/glm_output/scale_maps/"
fi

# --------------------------------------------------------------------------
# Step 7: Site-effect, pre vs post harmonization (template space, l0)
# --------------------------------------------------------------------------
if run 7; then
hr "Step 7: Site-effect comparison (pre vs post)"
GMASK="$OUT/template/group_mask.mif"
# Detect shell dirs (e.g. b1000) from the first session's template RISH
SHELLS=()
for d in "$OUT/template_rish/${SUBJECTS[0]}/$REF_SITE"/b*/; do SHELLS+=("$(basename "$d")"); done

for SH in "${SHELLS[@]}"; do
  BV="${SH#b}"
  # Build post-harmonization RISH l0: ref unchanged; targets x scale_l0[site]
  POST="$OUT/site_effect/$SH/post_rish"; mkdir -p "$POST"
  for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
    SRC="$OUT/template_rish/$SUBJ/$SITE/$SH/rish/rish_l0.mif"
    DST="$POST/${SUBJ}_${SITE}.mif"
    if [[ "$SITE" == "$REF_SITE" ]]; then
      cp -f "$SRC" "$DST"
    else
      SCALE="$OUT/glm_output/scale_maps/$SITE/$SH/scale_l0_${SITE}.mif"
      mrcalc "$SRC" "$SCALE" -mult "$DST" -force -quiet
    fi
  done; done
  # site-effect CSVs (site, rish_path) for pre and post
  PREC="$OUT/site_effect/$SH/pre.csv"; POSTC="$OUT/site_effect/$SH/post.csv"
  echo "site,rish_path" > "$PREC"; echo "site,rish_path" > "$POSTC"
  for SUBJ in "${SUBJECTS[@]}"; do for SITE in "${SITES[@]}"; do
    echo "$SITE,$OUT/template_rish/$SUBJ/$SITE/$SH/rish/rish_l0.mif" >> "$PREC"
    echo "$SITE,$POST/${SUBJ}_${SITE}.mif" >> "$POSTC"
  done; done
  echo "  [$SH] pre:";  rish-harmonize site-effect --site-list "$PREC"  --mask "$GMASK" -o "$OUT/site_effect/$SH/pre"  --n-permutations 2000 --seed 42
  echo "  [$SH] post:"; rish-harmonize site-effect --site-list "$POSTC" --mask "$GMASK" -o "$OUT/site_effect/$SH/post" --n-permutations 2000 --seed 42
done
fi

# --------------------------------------------------------------------------
# Step 8: QC report
# --------------------------------------------------------------------------
if run 8; then
hr "Step 8: QC report"
rish-harmonize qc-report \
    --glm-output "$OUT/glm_output" \
    --site-effect-dir "$OUT/site_effect" \
    -o "$OUT/qc_figures" || echo "  (qc-report needs the [viz] extra: pip install -e '.[viz]')"
fi

echo ""
echo "================================================================"
echo "  Pipeline complete. Output: $OUT"
echo "================================================================"
