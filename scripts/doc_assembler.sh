#!/bin/bash

# Document Assembly Script
# Moves all document files from subfolders into a centralized documents folder

# Configuration
SOURCE_DIR="${1:-.}"  # Use first argument or current directory
DEST_DIR="$2/documents"
LOG_FILE="document_assembly.log"
ORGANIZE_BY_YEAR=true

# Document file extensions to search for
EXTENSIONS=("pdf" "doc" "docx" "txt" "rtf" "odt" "xls" "xlsx" "ppt" "pptx" "odp" "ods")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${2}${1}${NC}"
}

# Function to check if exiftool is available
check_exiftool() {
    if command -v exiftool >/dev/null 2>&1; then
        return 0
    else
        print_status "Warning: exiftool not found. Install it for better date detection." "$YELLOW"
        print_status "Install with: apt-get install libimage-exiftool-perl (Ubuntu/Debian)" "$YELLOW"
        print_status "           or: brew install exiftool (macOS)" "$YELLOW"
        log_message "exiftool not available, using file modification dates"
        return 1
    fi
}

# Function to get file's creation year from EXIF data
get_exif_year() {
    local file="$1"
    local create_date
    
    # Try to get CreateDate from EXIF metadata
    create_date=$(exiftool -s -s -s -CreateDate "$file" 2>/dev/null)
    
    if [ -n "$create_date" ] && [ "$create_date" != "-" ]; then
        # Extract year from date format (YYYY:MM:DD HH:MM:SS)
        echo "$create_date" | cut -d':' -f1 2>/dev/null
    else
        # Try alternative date fields if CreateDate is not available
        local alt_date
        alt_date=$(exiftool -s -s -s -DateTimeOriginal -ModifyDate -FileModifyDate "$file" 2>/dev/null | head -1)
        if [ -n "$alt_date" ] && [ "$alt_date" != "-" ]; then
            echo "$alt_date" | cut -d':' -f1 2>/dev/null
        fi
    fi
}

# Function to get file's last modified year (fallback)
get_file_mod_year() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        stat -f "%Sm" -t "%Y" "$file" 2>/dev/null
    else
        # Linux
        stat -c "%Y" "$file" 2>/dev/null | xargs -I {} date -d "@{}" "+%Y" 2>/dev/null
    fi
}

# Function to get file year (EXIF first, then modification date)
get_file_year() {
    local file="$1"
    local year=""
    
    # First try EXIF data if exiftool is available
    if [ "$EXIFTOOL_AVAILABLE" = true ]; then
        year=$(get_exif_year "$file")
        if [ -n "$year" ] && [[ "$year" =~ ^[0-9]{4}$ ]]; then
            echo "$year"
            return 0
        fi
    fi
    
    # Fallback to file modification date
    year=$(get_file_mod_year "$file")
    if [ -n "$year" ] && [[ "$year" =~ ^[0-9]{4}$ ]]; then
        echo "$year"
        return 0
    fi
    
    # Return empty if no valid year found
    echo ""
}

# Function to create year directory
create_year_dir() {
    local year="$1"
    local year_dir="$DEST_DIR/$year"
    
    if [ ! -d "$year_dir" ]; then
        mkdir -p "$year_dir"
        print_status "Created year directory: $year" "$GREEN"
        log_message "Created year directory: $year_dir"
    fi
    
    echo "$year_dir"
}

print_status "Document Assembly Script Started" "$BLUE"
print_status "Source Directory: $(realpath "$SOURCE_DIR")" "$BLUE"
log_message "Script started - Source: $SOURCE_DIR"

# Check for exiftool availability
if check_exiftool; then
    EXIFTOOL_AVAILABLE=true
    print_status "exiftool found - will use EXIF CreateDate for date detection" "$GREEN"
    log_message "exiftool available - using EXIF metadata"
else
    EXIFTOOL_AVAILABLE=false
    print_status "Using file modification dates for organization" "$YELLOW"
fi

# Create destination directory if it doesn't exist
if [ ! -d "$DEST_DIR" ]; then
    mkdir -p "$DEST_DIR"
    print_status "Created destination directory: $DEST_DIR" "$GREEN"
    log_message "Created destination directory: $DEST_DIR"
else
    print_status "Using existing destination directory: $DEST_DIR" "$YELLOW"
fi

# Initialize counters
total_files=0
moved_files=0
skipped_files=0
error_files=0

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to handle file conflicts with year organization
handle_conflict() {
    local src_file="$1"
    local dest_dir="$2"
    local filename=$(basename "$src_file")
    local base_name="${filename%.*}"
    local extension="${filename##*.}"
    local counter=1
    local dest_file="$dest_dir/$filename"
    
    while [ -f "$dest_file" ]; do
        dest_file="$dest_dir/${base_name}_${counter}.${extension}"
        ((counter++))
    done
    
    echo "$dest_file"
}

print_status "Searching for document files..." "$BLUE"

# Build find command with all extensions
find_cmd="find \"$SOURCE_DIR\" -type f \\( "
for i in "${!EXTENSIONS[@]}"; do
    if [ $i -gt 0 ]; then
        find_cmd+=" -o "
    fi
    find_cmd+="-iname \"*.${EXTENSIONS[$i]}\""
done
find_cmd+=" \\)"

# Execute find and process files
while IFS= read -r -d '' file; do
    ((total_files++))
    
    # Skip files already in the destination directory
    if [[ "$file" == "$DEST_DIR"* ]]; then
        print_status "Skipping file already in destination: $(basename "$file")" "$YELLOW"
        ((skipped_files++))
        log_message "Skipped (already in destination): $file"
        continue
    fi
    
    filename=$(basename "$file")
    
    # Get file's creation year from EXIF or modification date
    file_year=$(get_file_year "$file")
    
    if [ -z "$file_year" ] || [ "$file_year" = "" ]; then
        print_status "Warning: Could not determine year for $filename, using 'unknown'" "$YELLOW"
        file_year="unknown"
        log_message "Warning: Could not determine year for $file"
    else
        # Log the method used for date detection
        if [ "$EXIFTOOL_AVAILABLE" = true ]; then
            exif_year=$(get_exif_year "$file")
            if [ -n "$exif_year" ] && [[ "$exif_year" =~ ^[0-9]{4}$ ]]; then
                log_message "Using EXIF CreateDate ($file_year) for $file"
            else
                log_message "Using file modification date ($file_year) for $file (no EXIF date)"
            fi
        else
            log_message "Using file modification date ($file_year) for $file"
        fi
    fi
    
    # Create year directory and get the destination directory
    if [ "$ORGANIZE_BY_YEAR" = true ]; then
        dest_dir=$(create_year_dir "$file_year")
    else
        dest_dir="$DEST_DIR"
    fi
    
    dest_file="$dest_dir/$filename"
    
    # Handle file conflicts by renaming
    if [ -f "$dest_file" ]; then
        dest_file=$(handle_conflict "$file" "$dest_dir")
        print_status "File conflict resolved: $filename -> $(basename "$dest_file") [$file_year]" "$YELLOW"
        log_message "File conflict resolved: $file -> $dest_file"
    fi
    
    # Move the file
    if mv "$file" "$dest_file" 2>/dev/null; then
        if [ "$EXIFTOOL_AVAILABLE" = true ]; then
            exif_year=$(get_exif_year "$file" 2>/dev/null)
            if [ -n "$exif_year" ] && [[ "$exif_year" =~ ^[0-9]{4}$ ]]; then
                print_status "Moved: $filename -> $file_year/ (EXIF date)" "$GREEN"
            else
                print_status "Moved: $filename -> $file_year/ (mod date)" "$GREEN"
            fi
        else
            print_status "Moved: $filename -> $file_year/ (mod date)" "$GREEN"
        fi
        ((moved_files++))
        log_message "Moved: $file -> $dest_file"
    else
        print_status "Error moving: $filename" "$RED"
        ((error_files++))
        log_message "Error moving: $file"
    fi
    
done < <(eval "$find_cmd" -print0 2>/dev/null)

# Print summary
echo
print_status "=== ASSEMBLY COMPLETE ===" "$BLUE"
print_status "Total files found: $total_files" "$BLUE"
print_status "Files moved: $moved_files" "$GREEN"
print_status "Files skipped: $skipped_files" "$YELLOW"
print_status "Errors: $error_files" "$RED"
print_status "Destination: $(realpath "$DEST_DIR")" "$BLUE"
print_status "Log file: $LOG_FILE" "$BLUE"

log_message "Script completed - Total: $total_files, Moved: $moved_files, Skipped: $skipped_files, Errors: $error_files"

# Final status
if [ $error_files -gt 0 ]; then
    print_status "Script completed with errors. Check $LOG_FILE for details." "$RED"
    exit 1
else
    print_status "Script completed successfully!" "$GREEN"
    exit 0
fi