#!/bin/bash

# Additional script specifically for handling corrupted video files
# This script tries multiple approaches for problematic files

echo "Checking and fixing corrupted video files..."

# Function to check if video is corrupted
check_video_corruption() {
    local file="$1"
    # Try to read basic metadata - if this fails, file is likely corrupted
    if ! exiftool -quiet -FileSize "$file" >/dev/null 2>&1; then
        return 1  # Corrupted
    fi
    return 0  # OK
}

# Function to attempt repair of corrupted MP4
attempt_repair() {
    local file="$1"
    local backup="${file}.backup"
    
    echo "Attempting to repair: $(basename "$file")"
    
    # Create backup
    cp "$file" "$backup"
    
    # Try using ffmpeg to remux the file (if available)
    if command -v ffmpeg &> /dev/null; then
        echo "  Trying ffmpeg repair..."
        if ffmpeg -i "$backup" -c copy -avoid_negative_ts make_zero "${file}.temp" -y >/dev/null 2>&1; then
            mv "${file}.temp" "$file"
            echo "  ✅ Repaired with ffmpeg"
            rm "$backup"
            return 0
        else
            rm -f "${file}.temp"
        fi
    fi
    
    # If ffmpeg fails or isn't available, restore backup and try filesystem date only
    mv "$backup" "$file"
    echo "  ⚠️ Cannot repair metadata, will set filesystem date only"
    return 1
}

# Process corrupted videos found in your directory
for file in /media/ayoub/data/private/phone_backups/organized/1970/*/VID-*.mp4; do
    [ -f "$file" ] || continue
    
    filename=$(basename "$file")
    
    # Check if it matches our pattern and extract date
    if [[ $filename =~ VID-([0-9]{4})([0-9]{2})([0-9]{2})-.*\.mp4$ ]]; then
        year="${BASH_REMATCH[1]}"
        month="${BASH_REMATCH[2]}"
        day="${BASH_REMATCH[3]}"
        
        # Skip if date is invalid
        if [ "$month" -lt 1 ] || [ "$month" -gt 12 ] || [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
            continue
        fi
        
        # Check if video appears corrupted
        if ! check_video_corruption "$file"; then
            echo "Found corrupted video: $filename"
            
            # Try to repair
            if attempt_repair "$file"; then
                # If repair successful, try setting metadata again
                exif_datetime="${year}:${month}:${day} 12:00:00"
                exiftool -overwrite_original \
                        -CreateDate="$exif_datetime" \
                        -ModifyDate="$exif_datetime" \
                        -MediaCreateDate="$exif_datetime" \
                        -quiet \
                        "$file" && echo "  ✅ Metadata fixed after repair"
            else
                # Just set filesystem date
                fs_date="${year}${month}${day}1200.00"
                touch -t "$fs_date" "$file" && echo "  ✅ Filesystem date set"
            fi
        fi
    fi
done

echo "Corrupted video processing complete."