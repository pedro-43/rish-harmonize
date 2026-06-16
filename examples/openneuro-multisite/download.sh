#!/bin/bash
# Download a small multi-site subset of ds000206 (DWI Traveling Human Phantom)
# directly from OpenNeuro's S3 bucket — no datalad / openneuro-cli needed.
#
# Traveling-subject design: the SAME subjects are scanned at every site, so
# after registration any residual RISH difference between sites is a pure
# site/scanner effect (no biological variability) — ideal for harmonization.
#
# Usage: ./download.sh
set -euo pipefail

BUCKET="https://s3.amazonaws.com/openneuro.org"
DS="ds000206"
ACQ="acq-GD31_run-01"            # single-shell b=1000, 31 directions
DATADIR="${DATADIR:-$(cd "$(dirname "$0")" && pwd)/data}"

SUBJECTS=(THP0001 THP0002 THP0003 THP0004 THP0005)
SITES=(CCF IOWA MGH)            # CCF = reference site

mkdir -p "$DATADIR"

# Resolve the exact session folder for a (subject, site) via an S3 listing,
# then download the 4 DWI files + the T1w anat.
for SUBJ in "${SUBJECTS[@]}"; do
  for SITE in "${SITES[@]}"; do
    # Find the GD31 run-01 dwi key for this subject+site (first matching visit)
    KEY=$(curl -sL "${BUCKET}/?list-type=2&prefix=${DS}/sub-${SUBJ}/&max-keys=600" \
          | tr '<' '\n' | grep 'Key>' | sed 's#^Key>##' \
          | grep "/ses-THP${SUBJ#THP}${SITE}[0-9]*/dwi/.*${ACQ}_dwi.nii.gz$" | head -1 || true)
    if [[ -z "$KEY" ]]; then
      echo "  [!] no ${ACQ} for sub-${SUBJ} @ ${SITE}, skipping"
      continue
    fi
    SES=$(echo "$KEY" | sed -E 's#.*/(ses-[^/]+)/.*#\1#')
    BASE=$(basename "$KEY" .nii.gz)             # ..._dwi
    OUT="$DATADIR/sub-${SUBJ}/${SES}"
    mkdir -p "$OUT/dwi" "$OUT/anat"

    for ext in nii.gz bval bvec json; do
      f="$OUT/dwi/${BASE}.${ext}"
      [[ -f "$f" ]] && continue
      curl -sL "${BUCKET}/${DS}/sub-${SUBJ}/${SES}/dwi/${BASE}.${ext}" -o "$f"
    done

    # T1w (first run) for masking / registration
    T1KEY=$(curl -sL "${BUCKET}/?list-type=2&prefix=${DS}/sub-${SUBJ}/${SES}/anat/&max-keys=40" \
            | tr '<' '\n' | grep 'Key>' | sed 's#^Key>##' | grep 'T1w.nii.gz$' | head -1 || true)
    if [[ -n "$T1KEY" ]]; then
      t1="$OUT/anat/$(basename "$T1KEY")"
      [[ -f "$t1" ]] || curl -sL "${BUCKET}/${T1KEY}" -o "$t1"
    fi
    echo "  [ok] sub-${SUBJ} @ ${SITE}  ($SES)"
  done
done
echo "Done. Data in: $DATADIR"
