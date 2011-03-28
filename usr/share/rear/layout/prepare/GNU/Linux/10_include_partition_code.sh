# Generate code to partition the disks

if ! type -p parted &>/dev/null ; then
    return
fi

# Test for features in parted

# true if parted accepts values in units other than megabytes
FEATURE_PARTED_ANYUNIT=
# true if parted can align partitions
FEATURE_PARTED_ALIGNMENT=

# Test by using the parted version numbers...
parted_version=$(get_version parted -v)

if [ -z "$parted_version" ] ; then
    BugError "Function get_version could not detect parted version."
elif version_newer "$parted_version" 2.0 ; then
    # All features supported
    FEATURE_PARTED_ANYUNIT="y"
    FEATURE_PARTED_ALIGNMENT="y"
elif version_newer "$parted_version" 1.8 ; then
    FEATURE_PARTED_ANYUNIT="y"
fi

# Partition a disk
partition_disk() {
    read component disk size label junk <$1

    if [ -z "$label" ] ; then
        # LVM on whole disk can lead to no label available.
        Log "No disk label information for disk $disk."
        return 0
    fi
    
    # Find out the actual disk size
    disk_size=$( get_disk_size "$disk" )
    
    if [ $disk_size -eq 0 ]; then
        Error "Disk $disk has size 0, unable to continue."
    fi

    cat >> $LAYOUT_CODE <<EOF
LogPrint "Creating partitions for disk $disk ($label)"
parted -s $disk mklabel $label 1>&2
EOF
    
    let start=32768 # start after one cylinder 63*512 + multiple of 4k = 64*512
    let end=0
    while read part odisk size type flags name junk; do
        
        # calculate the end of the partition.
        let end=$start+$size
        
        # test to make sure we're not past the end of the disk
        if [ $end -gt $disk_size ] ; then
            LogPrint "Partition $name size reduced to fit on disk."
            let end=$disk_size
        fi
        
        # extended partitions run to the end of disk...
        if [ "$type" = "extended" ] ; then
            let end=$disk_size
        fi
        
        if [ -n "$FEATURE_PARTED_ANYUNIT" ] ; then
cat <<EOF >> $LAYOUT_CODE
parted -s $disk mkpart $type ${start}B $(($end-1))B 1>&2
EOF
        else
            # Old versions of parted accept only sizes in megabytes...
            if [ $start -gt 0 ] ; then
                let start_mb=$start/1024/1024
            else
                start_mb=0
            fi
            let end_mb=$end/1024/1024
cat <<EOF >> $LAYOUT_CODE
parted -s $disk mkpart $type $start_mb $end_mb 1>&2
EOF
        fi

        # the start of the next partition is where this one ends
        # We can't use $end because of extended partitions
        # extended partitions have a small actual size as reported by sysfs
        let start=$start+${size%B}
        
        # round starting size to next multiple of 4096
        # 4096 is a good match for most device's block size
        start=$( echo "$start" | awk '{print $1+4096-($1%4096);}')
        
        # Get the partition number from the name
        number=$(echo "$name" | grep -o -E "[0-9]+$")
        
        flags="$(echo $flags | tr ',' ' ')"
        for flag in $flags ; do
            if [ "$flag" = "none" ] ; then
                continue
            fi
            echo "parted -s $disk set $number $flag on 1>&2" >> $LAYOUT_CODE
        done
    done < <(grep "^part $disk" $LAYOUT_FILE)

cat >> $LAYOUT_CODE <<EOF
# Wait some time before advancing
sleep 20

EOF
}