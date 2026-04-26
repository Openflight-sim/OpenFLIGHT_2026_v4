#!/bin/bash
# Generate AVL reference data for all .avl test cases
# Output: avl_reference.csv

RUNS_DIR="F:/WORK/CAPAS/JAVL/15_AVL/AVL3.52rel09032025/runs"
AVL_EXE="F:/WORK/CAPAS/JAVL/15_AVL/AVL3.52rel09032025/binw32/avl3.51-32.exe"
OUTFILE="$(dirname "$0")/avl_reference.csv"
ALPHA=5.0

echo "# AVL 3.52 reference data at alpha=${ALPHA} deg" > "$OUTFILE"
echo "# name,CLtot,CDtot,Cmtot,CLff,CDff,e" >> "$OUTFILE"

cd "$RUNS_DIR"

for avl_file in *.avl; do
    [[ "$avl_file" == ._* ]] && continue
    name="${avl_file%.avl}"

    # Create temp command file
    tmpfile="/tmp/avl_cmds_${name}.txt"
    cat > "$tmpfile" << EOF
load ${avl_file}
oper
a a ${ALPHA}
x
ft

quit
EOF

    # Run AVL, capture output, suppress stderr
    output=$(cat "$tmpfile" | "$AVL_EXE" 2>/dev/null || true)
    rm -f "$tmpfile"

    # Parse values from output
    cl=$(echo "$output" | grep -m1 "CLtot" | sed 's/.*CLtot *= *//' | awk '{print $1}')
    cd=$(echo "$output" | grep -m1 "CDtot" | sed 's/.*CDtot *= *//' | awk '{print $1}')
    cm=$(echo "$output" | grep -m1 "Cmtot" | sed 's/.*Cmtot *= *//' | awk '{print $1}')
    clff=$(echo "$output" | grep -m1 "CLff" | sed 's/.*CLff *= *//' | awk '{print $1}')
    cdff=$(echo "$output" | grep -m1 "CDff *= *" | sed 's/.*CDff *= *//' | awk '{print $1}')
    e=$(echo "$output" | grep -m1 " e =" | sed 's/.*e *= *//' | awk '{print $1}')

    if [[ -n "$cl" && "$cl" != "" ]]; then
        echo "${name},${cl},${cd},${cm},${clff},${cdff},${e}" >> "$OUTFILE"
        printf "  %-25s OK   CL=%-10s CDff=%-10s Cm=%s\n" "$name" "$cl" "$cdff" "$cm"
    else
        printf "  %-25s FAIL\n" "$name"
    fi
done

echo ""
echo "Reference data written to: $OUTFILE"
echo "Total cases: $(grep -v '^#' "$OUTFILE" | grep -c '.')"
