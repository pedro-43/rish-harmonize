#!/bin/bash
# Shared configuration for the OpenNeuro ds000206 multi-site harmonization example.
#
# Dataset: ds000206 "DWI Traveling Human Phantom" (CC0). The SAME subjects are
# scanned at every site, so after registration any residual RISH difference
# between sites is a pure site/scanner effect (no biological variability) — the
# cleanest possible setting to demonstrate harmonization.
#
# Acquisition: acq-GD31 run-01 (single-shell b=1000, 31 directions -> lmax=6).

# --- paths -------------------------------------------------------------------
EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATADIR="${DATADIR:-$EX_DIR/data}"        # BIDS-style download tree (download.sh)
OUT="${OUT:-$EX_DIR/processing}"          # all derivatives land here

# --- cohort ------------------------------------------------------------------
SUBJECTS=(THP0001 THP0002 THP0003 THP0004 THP0005)
SITES=(CCF IOWA MGH)
REF_SITE="CCF"                            # reference site for harmonization

# --- MRtrix on PATH (edit for your install) ----------------------------------
# If MRtrix3 is in a conda/venv env, prepend it here. Left as-is otherwise.
# export PATH="/path/to/mrtrix3/bin:$PATH"

NTHREADS="${NTHREADS:-4}"

# --- helpers -----------------------------------------------------------------

# Resolve the session directory for a (subject, site) under $DATADIR.
# Sessions are named ses-THP<NNNN><SITE><visit>; we take the first match.
session_dir() {
    local subj="$1" site="$2"
    local d
    d=$(find "$DATADIR/sub-$subj" -maxdepth 1 -type d -name "ses-THP${subj#THP}${site}*" 2>/dev/null | sort | head -1)
    echo "$d"
}

# Path to the raw DWI basename (without extension) for a (subject, site).
dwi_base() {
    local subj="$1" site="$2" ses
    ses=$(session_dir "$subj" "$site")
    [[ -z "$ses" ]] && return 1
    local f
    f=$(find "$ses/dwi" -name "*_dwi.nii.gz" | sort | head -1)
    echo "${f%.nii.gz}"
}
