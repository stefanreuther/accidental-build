#!/bin/sh

success=true
suffix=0
for i in t_*.sh; do
    # Create work directory
    workdir=/tmp/t$$.$suffix
    if ! mkdir "$workdir"; then
        echo "Unable to create work directory, abort." >&2
        exit 1
    fi

    # Run test
    printf "%s..." "$i"
    if sh "$i" "$workdir" >test.log 2>&1
    then
        echo " OK"
        rm -rf "$workdir"
    else
        echo " FAIL"
        echo "  Output:"
        sed "s/^/    /" <test.log
        echo "  Work directory left in $workdir"
        success=false
    fi

    rm -f test.log
done
$success
