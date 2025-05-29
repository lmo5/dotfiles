#!/bin/bash

# Script to fix EXIF DateTimeOriginal (images) and creation dates (videos) based on filename
# Usage: ./fix_media_dates.sh [directory_path]
# If no directory is provided, current directory is used

# Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
    echo "Error: exiftool is not installed."
    echo "Install it with: sudo apt-get install libimage-exiftool-perl"
    exit 1
fi

# Set directory to process (default to current directory)
DIR="${1:-.}"

# Check if directory exists
if [ ! -d "$DIR" ]; then
    echo "Error: Directory '$DIR' does not exist."
    exit 1
fi

echo "Processing media files in directory: $DIR"
echo "Using exiftool to set creation dates"
echo "----------------------------------------"

# Counter for processed files
processed=0
skipped=0

# Function to process a single file
process_file() {
    local file="$1"
    local file_type="$2"  # "image" or "video"
    
    # Extract filename without path
    filename=$(basename "$file")
    
    # Extract date from filename using regex for both IMG and VID patterns
    if [[ $filename =~ (IMG|VID)-([0-9]{4})([0-9]{2})([0-9]{2})-.*\.(jpg|jpeg|png|gif|bmp|tiff|webp|mp4|avi|mov|mkv|wmv|flv|webm|m4v|3gp|JPG|JPEG|PNG|GIF|BMP|TIFF|WEBP|MP4|AVI|MOV|MKV|WMV|FLV|WEBM|M4V|3GP)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        year="${BASH_REMATCH[2]}"
        month="${BASH_REMATCH[3]}"
        day="${BASH_REMATCH[4]}"
        
        # Validate date components
        if [ "$month" -lt 1 ] || [ "$month" -gt 12 ] || [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
            echo "⚠️  Skipping $filename - Invalid date: $year-$month-$day"
            ((skipped++))
            return
        fi
        
        # Format date for EXIF (YYYY:MM:DD HH:MM:SS)
        exif_datetime="${year}:${month}:${day} 12:00:00"
        
        # Set different metadata fields based on file type
        if [ "$file_type" = "image" ]; then
            # For images: set EXIF DateTimeOriginal, DateTime, and CreateDate
            if exiftool -overwrite_original \
                       -DateTimeOriginal="$exif_datetime" \
                       -DateTime="$exif_datetime" \
                       -CreateDate="$exif_datetime" \
                       -quiet \
                       "$file"; then
                echo "✅ Fixed image: $filename -> $exif_datetime"
                ((processed++))
            else
                echo "❌ Failed to fix image: $filename"
                ((skipped++))
            fi
        else
            # For videos: set CreateDate, ModifyDate, and MediaCreateDate
            if exiftool -overwrite_original \
                       -CreateDate="$exif_datetime" \
                       -ModifyDate="$exif_datetime" \
                       -MediaCreateDate="$exif_datetime" \
                       -DateTimeOriginal="$exif_datetime" \
                       -quiet \
                       "$file"; then
                echo "✅ Fixed video: $filename -> $exif_datetime"
                ((processed++))
            else
                echo "❌ Failed to fix video: $filename"
                ((skipped++))
            fi
        fi
    else
        echo "⚠️  Skipping $filename - doesn't match expected pattern"
        ((skipped++))
    fi
}

# Process image files
echo "Processing image files..."
for file in "$DIR"/{IMG,VID}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.{jpg,jpeg,png,gif,bmp,tiff,webp,JPG,JPEG,PNG,GIF,BMP,TIFF,WEBP}; do
    [ -f "$file" ] || continue
    process_file "$file" "image"
done

# Process video files
echo "Processing video files..."
for file in "$DIR"/{IMG,VID}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.{mp4,avi,mov,mkv,wmv,flv,webm,m4v,3gp,MP4,AVI,MOV,MKV,WMV,FLV,WEBM,M4V,3GP}; do
    [ -f "$file" ] || continue
    process_file "$file" "video"
done

echo "----------------------------------------"
echo "Summary:"
echo "  Processed: $processed files"
echo "  Skipped: $skipped files"

if [ $processed -eq 0 ] && [ $skipped -eq 0 ]; then
    echo "No matching media files found in $DIR"
    echo "Expected patterns:"
    echo "  Images: IMG-YYYYMMDD-*.extension"
    echo "  Videos: VID-YYYYMMDD-*.extension"
fi

echo ""
echo "Note: Dates set to YYYY:MM:DD 12:00:00 format"
echo "Verify with:"
echo "  Images: exiftool -DateTimeOriginal filename.jpg"
echo "  Videos: exiftool -CreateDate filename.mp4"