#!/bin/bash

# Photo and Video Organizer Script
# Organizes files by modification date into Year/Month folder structure

# Configuration
SOURCE_DIR="${1:-$(pwd)}"  # Use provided directory or current directory
OUTPUT_DIR="${2:-$(pwd)/organized_media}"  # Output directory
ACTION="${3:-organize}"  # organize, rollback, or dry-run
UNKNOWN_DIR="$OUTPUT_DIR/to-organize-unknown"  # Directory for files with unknown dates
LOG_FILE="$OUTPUT_DIR/.organization_log.txt"  # Log file for rollback functionality

# Supported file extensions (case insensitive)
PHOTO_EXTENSIONS="jpg jpeg png gif bmp tiff tif webp heic raw cr2 nef arw"
VIDEO_EXTENSIONS="mp4 avi mov mkv wmv flv webm m4v 3gp mpg mpeg"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to log file operations for rollback
log_operation() {
    local operation="$1"
    local source="$2"
    local destination="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "$ACTION" != "dry-run" ]]; then
        echo "$timestamp|$operation|$source|$destination" >> "$LOG_FILE"
    fi
}

# Function to create unknown date directory
create_unknown_dir() {
    if [[ "$ACTION" != "dry-run" ]]; then
        mkdir -p "$UNKNOWN_DIR"
    fi
    echo "$UNKNOWN_DIR"
}

is_media_file() {
    local file="$1"
    local extension="${file##*.}"
    extension=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
    
    local all_extensions="$PHOTO_EXTENSIONS $VIDEO_EXTENSIONS"
    for ext in $all_extensions; do
        if [[ "$extension" == "$ext" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to validate date format and values
is_valid_date() {
    local date_str="$1"
    
    # Check if date matches YYYY-MM format
    if [[ ! "$date_str" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        return 1
    fi
    
    # Extract year and month
    local year="${date_str%-*}"
    local month="${date_str#*-}"
    
    # Check for invalid values (0000 year or 00 month)
    if [[ "$year" == "0000" || "$month" == "00" ]]; then
        return 1
    fi
    
    # Check for reasonable year range (1900-2030)
    if [[ "$year" -lt 1900 || "$year" -gt 2030 ]]; then
        return 1
    fi
    
    # Check for valid month (01-12)
    if [[ "$month" -lt 1 || "$month" -gt 12 ]]; then
        return 1
    fi
    
    return 0
}

# Function to extract and validate EXIF date
extract_exif_date() {
    local exif_date="$1"
    
    if [[ -n "$exif_date" && "$exif_date" != "-" ]]; then
        # Convert from "2024:06:23 18:02:56" or "0000:00:00 00:00:00" to "2024-06" format
        local year_month=$(echo "$exif_date" | sed 's/:\([0-9][0-9]\):\([0-9][0-9]\).*/:\1/' | tr ':' '-')
        
        # Validate the extracted date
        if is_valid_date "$year_month"; then
            echo "$year_month"
            return 0
        fi
    fi
    
    return 1
}

get_file_date() {
    local file="$1"
    local date_found=""
    local extracted_date=""
    
    # Method 1: Try EXIF CreateDate for photos and videos (if exiftool is available)
    if command -v exiftool >/dev/null 2>&1; then
        # Get CreateDate in original format: 2024:06:23 18:02:56
        date_found=$(exiftool -CreateDate -s -s -s "$file" 2>/dev/null | head -1)
        
        if extracted_date=$(extract_exif_date "$date_found"); then
            echo "$extracted_date"
            return 0
        fi
        
        # Fallback: Try DateTimeOriginal if CreateDate failed
        date_found=$(exiftool -DateTimeOriginal -s -s -s "$file" 2>/dev/null | head -1)
        if extracted_date=$(extract_exif_date "$date_found"); then
            echo "$extracted_date"
            return 0
        fi
        
        # Fallback: Try ModifyDate
        date_found=$(exiftool -ModifyDate -s -s -s "$file" 2>/dev/null | head -1)
        if extracted_date=$(extract_exif_date "$date_found"); then
            echo "$extracted_date"
            return 0
        fi
    fi
    
    # Method 2: Try MediaInfo for videos (if available)
    if command -v mediainfo >/dev/null 2>&1; then
        date_found=$(mediainfo --Inform="General;%Recorded_Date%" "$file" 2>/dev/null)
        if [[ -n "$date_found" ]]; then
            # Try to extract year-month from various MediaInfo date formats
            local year_month=$(echo "$date_found" | grep -oE '[0-9]{4}[-/:][0-9]{2}' | head -1 | tr ':/' '-')
            if [[ "$year_month" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
                echo "$year_month"
                return 0
            fi
        fi
    fi
    
    # Method 3: Fall back to file modification time
    local mod_date=$(stat -c %Y "$file" 2>/dev/null | xargs -I {} date -d @{} +%Y-%m 2>/dev/null)
    if [[ "$mod_date" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "$mod_date"
        return 0
    fi
    
    # Method 4: Try file birth time (creation time) if available
    local birth_time=$(stat -c %W "$file" 2>/dev/null)
    if [[ "$birth_time" != "0" && -n "$birth_time" ]]; then
        local birth_date=$(date -d @"$birth_time" +%Y-%m 2>/dev/null)
        if [[ "$birth_date" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
            echo "$birth_date"
            return 0
        fi
    fi
    
    # If all methods fail, return empty
    echo ""
}

# Function to create directory structure
create_directories() {
    local year_month="$1"
    local year="${year_month%-*}"
    local month="${year_month#*-}"
    
    local year_dir="$OUTPUT_DIR/$year"
    local month_dir="$year_dir/$month"
    
    if [[ "$ACTION" != "dry-run" ]]; then
        mkdir -p "$month_dir"
    fi
    
    echo "$month_dir"
}

# Function to move or copy file
organize_file() {
    local source_file="$1"
    local dest_dir="$2"
    local filename=$(basename "$source_file")
    local dest_file="$dest_dir/$filename"
    
    # Handle duplicate filenames
    local counter=1
    local base_name="${filename%.*}"
    local extension="${filename##*.}"
    
    while [[ -e "$dest_file" && "$dest_file" != "$source_file" ]]; do
        if [[ "$extension" == "$filename" ]]; then
            # No extension
            dest_file="$dest_dir/${base_name}_${counter}"
        else
            dest_file="$dest_dir/${base_name}_${counter}.${extension}"
        fi
        counter=$((counter + 1))
    done
    
    if [[ "$dest_file" == "$source_file" ]]; then
        print_status $YELLOW "  Skipping (already in correct location): $filename"
        return 0
    fi
    
    if [[ "$ACTION" == "dry-run" ]]; then
        print_status $BLUE "  Would move: $source_file -> $dest_file"
    else
        if mv "$source_file" "$dest_file" 2>/dev/null; then
            print_status $GREEN "  Moved: $filename -> $dest_dir"
            log_operation "MOVE" "$source_file" "$dest_file"
        else
            print_status $RED "  Failed to move: $filename"
            return 1
        fi
    fi
    
    return 0
}

# Rollback function
rollback_organization() {
    print_status $BLUE "Rollback Mode - Restoring files to original locations"
    print_status $BLUE "===================================================="
    echo
    
    if [[ ! -f "$LOG_FILE" ]]; then
        print_status $RED "Error: No log file found at $LOG_FILE"
        print_status $RED "Cannot perform rollback without organization log."
        exit 1
    fi
    
    local rollback_count=0
    local failed_rollback=0
    
    # Read log file in reverse order
    tac "$LOG_FILE" | while IFS='|' read -r timestamp operation source destination; do
        if [[ "$operation" == "MOVE" ]]; then
            if [[ -f "$destination" ]]; then
                local source_dir=$(dirname "$source")
                mkdir -p "$source_dir" 2>/dev/null
                
                if mv "$destination" "$source" 2>/dev/null; then
                    print_status $GREEN "  Restored: $(basename "$destination") -> $source"
                    rollback_count=$((rollback_count + 1))
                else
                    print_status $RED "  Failed to restore: $(basename "$destination")"
                    failed_rollback=$((failed_rollback + 1))
                fi
            else
                print_status $YELLOW "  File not found (may have been moved manually): $destination"
            fi
        fi
    done
    
    # Remove empty directories
    if [[ -d "$OUTPUT_DIR" ]]; then
        find "$OUTPUT_DIR" -type d -empty -delete 2>/dev/null
    fi
    
    # Remove log file after successful rollback
    if [[ $failed_rollback -eq 0 ]]; then
        rm -f "$LOG_FILE"
        print_status $GREEN "Rollback completed successfully!"
    else
        print_status $YELLOW "Rollback completed with $failed_rollback failed operations."
        print_status $YELLOW "Log file preserved for manual inspection."
    fi
}

main() {
    print_status $BLUE "Photo and Video Organizer"
    print_status $BLUE "========================"
    echo
    
    # Handle rollback action
    if [[ "$ACTION" == "rollback" ]]; then
        rollback_organization
        exit 0
    fi
    
    # Validate source directory
    if [[ ! -d "$SOURCE_DIR" ]]; then
        print_status $RED "Error: Source directory '$SOURCE_DIR' does not exist!"
        exit 1
    fi
    
    print_status $YELLOW "Source directory: $SOURCE_DIR"
    print_status $YELLOW "Output directory: $OUTPUT_DIR"
    
    if [[ "$ACTION" == "dry-run" ]]; then
        print_status $YELLOW "DRY RUN MODE - No files will be moved"
    fi
    echo
    
    # Create output directory
    if [[ "$ACTION" != "dry-run" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
    
    # Initialize counters
    local total_files=0
    local processed_files=0
    local failed_files=0
    local unknown_date_files=0
    
    # Find and process all media files
    print_status $BLUE "Scanning for media files..."
    
    while IFS= read -r -d '' file; do
        if is_media_file "$file"; then
            total_files=$((total_files + 1))
            
            # Get file date
            local file_date=$(get_file_date "$file")
            
            if [[ -n "$file_date" ]]; then
                local year="${file_date%-*}"
                local month="${file_date#*-}"
                local month_name=$(date -d "$year-$month-01" +%B 2>/dev/null || echo "$month")
                
                print_status $YELLOW "Processing: $(basename "$file") (${month_name} ${year})"
                
                # Create directory structure
                local dest_dir=$(create_directories "$file_date")
                
                # Move file
                if organize_file "$file" "$dest_dir"; then
                    processed_files=$((processed_files + 1))
                else
                    failed_files=$((failed_files + 1))
                fi
            else
                print_status $RED "Could not determine date for: $(basename "$file")"
                # Move to unknown directory
                local unknown_dir=$(create_unknown_dir)
                if organize_file "$file" "$unknown_dir"; then
                    unknown_date_files=$((unknown_date_files + 1))
                else
                    failed_files=$((failed_files + 1))
                fi
            fi
        fi
    done < <(find "$SOURCE_DIR" -type f -print0)
    
    # Print summary
    echo
    print_status $BLUE "Organization Summary"
    print_status $BLUE "==================="
    echo "Total media files found: $total_files"
    echo "Successfully organized: $processed_files"
    echo "Files with unknown dates: $unknown_date_files"
    echo "Failed: $failed_files"
    
    if [[ "$ACTION" == "dry-run" ]]; then
        echo
        print_status $YELLOW "This was a dry run. To actually organize files, run:"
        print_status $YELLOW "$0 \"$SOURCE_DIR\" \"$OUTPUT_DIR\" organize"
    fi
}

# Help function
show_help() {
    echo "Photo and Video Organizer"
    echo "Usage: $0 [SOURCE_DIR] [OUTPUT_DIR] [ACTION]"
    echo
    echo "Parameters:"
    echo "  SOURCE_DIR  - Directory containing photos/videos (default: current directory)"
    echo "  OUTPUT_DIR  - Directory to organize files into (default: ./organized_media)"
    echo "  ACTION      - Action to perform:"
    echo "                'organize' - Organize files (default)"
    echo "                'dry-run'  - Preview what will happen"
    echo "                'rollback' - Restore files to original locations"
    echo
    echo "Examples:"
    echo "  $0                                          # Organize current directory"
    echo "  $0 /path/to/photos                         # Organize specific directory"
    echo "  $0 /path/to/photos /path/to/output         # Custom output directory"
    echo "  $0 /path/to/photos /path/to/output dry-run # Preview only"
    echo "  $0 /path/to/photos /path/to/output rollback # Rollback organization"
    echo
    echo "Features:"
    echo "  - Uses EXIF CreateDate for accurate photo/video dating"
    echo "  - Date format handled: 2024:06:23 18:02:56 -> organized into 2024/06/"
    echo "  - Files with unknown dates go to: OUTPUT_DIR/to-organize-unknown/"
    echo "  - All operations are logged for rollback capability"
    echo "  - Duplicate filenames are handled automatically"
    echo "  - Requires: exiftool (recommended), mediainfo (optional)"
    echo
    echo "Installation of required tools:"
    echo "  Ubuntu/Debian: sudo apt-get install libimage-exiftool-perl mediainfo"
    echo "  macOS: brew install exiftool mediainfo"
    echo
    echo "Supported formats:"
    echo "  Photos: $PHOTO_EXTENSIONS"
    echo "  Videos: $VIDEO_EXTENSIONS"
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Run main function based on action
if [[ "$ACTION" == "rollback" ]]; then
    rollback_organization
else
    main
fi