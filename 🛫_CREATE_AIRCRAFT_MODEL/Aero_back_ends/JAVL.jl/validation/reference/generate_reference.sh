#!/bin/bash
# ──────────────────────────────────────────────────────────────
# generate_reference.sh — Generate AVL 3.52 reference data
#
# This script runs the Fortran AVL 3.52 executable on all .avl
# test cases at alpha=5° and extracts CL, CD, Cm, CLff, CDff, e.
#
# Usage:
#   cd JAVL.jl/validation/reference
#   bash generate_reference.sh
#
# Requirements:
#   - avl3.51-32.exe in this directory (Windows 32-bit executable)
#   - All .avl and .dat files in ../cases/
# ──────────────────────────────────────────────────────────────

AVL_EXE="./avl3.51-32.exe"
CASES_DIR="../cases"
OUTPUT_CSV="avl_reference.csv"

if [ ! -f "$AVL_EXE" ]; then
    echo "ERROR: AVL executable not found: $AVL_EXE"
    echo "Place avl3.51-32.exe in this directory."
    exit 1
fi

echo "# AVL 3.52 Reference Data — alpha=5.0°" > "$OUTPUT_CSV"
echo "# Generated $(date)" >> "$OUTPUT_CSV"
echo "# name,CL,CD,Cm,CLff,CDff,e" >> "$OUTPUT_CSV"

for avlfile in "$CASES_DIR"/*.avl; do
    name=$(basename "$avlfile" .avl)
    echo "  Running: $name"

    # Create AVL command script
    cat > /tmp/avl_cmd.txt << 'CMDS'
oper
a a 5.0
x

st

quit
CMDS

    # Run AVL and capture output
    output=$(cd "$CASES_DIR" && "$OLDPWD/$AVL_EXE" < /tmp/avl_cmd.txt "$name.avl" 2>/dev/null)

    # Extract values from stability-axis output
    CL=$(echo "$output" | grep -m1 "CLtot" | awk '{print $3}')
    CD=$(echo "$output" | grep -m1 "CDtot" | awk '{print $3}')
    CM=$(echo "$output" | grep -m1 "Cmtot" | awk '{print $3}')
    CLff=$(echo "$output" | grep -m1 "CLff" | awk '{for(i=1;i<=NF;i++) if($i=="CLff") print $(i+2)}')
    CDff=$(echo "$output" | grep -m1 "CDff" | awk '{for(i=1;i<=NF;i++) if($i=="CDff") print $(i+2)}')
    E=$(echo "$output" | grep -m1 "e =" | awk '{for(i=1;i<=NF;i++) if($i=="e") print $(i+2)}')

    # Default to 0 if not found
    CL=${CL:-0.0}; CD=${CD:-0.0}; CM=${CM:-0.0}
    CLff=${CLff:-0.0}; CDff=${CDff:-0.0}; E=${E:-0.0}

    echo "$name,$CL,$CD,$CM,$CLff,$CDff,$E" >> "$OUTPUT_CSV"
done

echo ""
echo "Reference data written to: $OUTPUT_CSV"
echo "Cases processed: $(grep -v '^#' "$OUTPUT_CSV" | grep -c ',')"
