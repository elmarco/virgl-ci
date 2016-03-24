#!/bin/bash

set -e
set -x

PREFIX="$(pwd)"
me=`basename "$0"`


RUN="$PREFIX/run"
XONOTIC="$PREFIX/xonotic.dat"
GLMARK="$PREFIX/glmark.dat"
PIGLIT="$PREFIX/piglit.dat"
rm -f "$XONOTIC" "$GLMARK" "$PIGLIT"

cd "$RUN"
for date in *; do
    if [ ! -f "$date/xonotic/output" ]; then
	continue
    fi
    DATE="$DATE $date"
done

# XONO
cd "$RUN"
for date in $DATE; do
    echo "$(cat "$date/xonotic/output" | cut -f5 -d' ') $date" >> "$XONOTIC"
done
cd "$PREFIX"
gnuplot -e "plottitle='xonotic'; inputfile='$XONOTIC'; outputfile='xonotic.png'" virgl-plot

#GLMARK
cd "$RUN"
for date in $DATE; do
    echo "$(cat "$date/glmark2/output" | grep Score | cut -d ' ' -f 37) $date" >> "$GLMARK"
done
cd "$PREFIX"
gnuplot -e "plottitle='glmark'; inputfile='$GLMARK'; outputfile='glmark.png'" virgl-plot

# PIGLIT
cd "$RUN"
echo "Pass Fail Crash Skip" > "$PIGLIT"
for date in $DATE; do
    PASS=$(cat "$date/piglit/summary" | sed 's/  */ /g' | grep ' pass:' | cut -f3 -d' ')
    FAIL=$(cat "$date/piglit/summary" | sed 's/  */ /g' | grep ' fail:' | cut -f3 -d' ')
    CRASH=$(cat "$date/piglit/summary" | sed 's/  */ /g' | grep ' crash:' | cut -f3 -d' ')
    SKIP=$(cat "$date/piglit/summary" | sed 's/  */ /g' | grep ' skip:' | cut -f3 -d' ')
    echo "$PASS $FAIL $CRASH $SKIP $date" >> "$PIGLIT"
done
cd "$PREFIX"
gnuplot virgl-piglit-plot
