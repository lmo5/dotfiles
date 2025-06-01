#!/bin/bash

# --- Help function ---
show_help() {
    echo "Usage: $0 [OPTIONS] <target_directory>"
    echo
    echo "Remove duplicate files (images, videos, documents, and other files) from the specified directory."
    echo
    echo "Arguments:"
    echo "  target_directory    Directory to scan for duplicates"
    echo
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -t, --types TYPE   File types to scan (default: all)"
    echo "                     Options: images, videos, music, documents, archives, all"
    echo "  -d, --duplicates   Custom duplicates directory (default: <target>/duplicates)"
    echo
    echo "Examples:"
    echo "  $0 /path/to/media"
    echo "  $0 --types images /path/to/photos"
    echo "  $0 --types videos --duplicates /tmp/dupes /path/to/videos"
    echo
}

# --- Default configuration ---
SCAN_TYPES="all"
DUPLICATES_DIR=""
TARGET_DIR=""

# --- Parse command line arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -t|--types)
            SCAN_TYPES="$2"
            shift 2
            ;;
        -d|--duplicates)
            DUPLICATES_DIR="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$1"
            else
                echo "Error: Multiple target directories specified"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# --- Validate arguments ---
if [ -z "$TARGET_DIR" ]; then
    echo "Error: Target directory not specified"
    show_help
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Target directory '$TARGET_DIR' does not exist"
    exit 1
fi

# Set default duplicates directory if not specified
if [ -z "$DUPLICATES_DIR" ]; then
    DUPLICATES_DIR="$TARGET_DIR/duplicates"
fi

# Validate scan types
case $SCAN_TYPES in
    images|videos|music|documents|archives|all)
        ;;
    *)
        echo "Error: Invalid scan type '$SCAN_TYPES'"
        echo "Valid types: images, videos, music, documents, archives, all"
        exit 1
        ;;
esac

# --- Configuration ---
SCAN_OUTPUT="/tmp/czkawka_duplicates_$(date +%s).txt"

echo "=== Duplicate File Remover ==="
echo "Target directory: $TARGET_DIR"
echo "Duplicates directory: $DUPLICATES_DIR"
echo "Scan types: $SCAN_TYPES"
echo "Output file: $SCAN_OUTPUT"
echo

# Create the duplicates folder if it doesn't exist
mkdir -p "$DUPLICATES_DIR"

# --- Function to run czkawka scan ---
run_scan() {
    local scan_type=$1
    local temp_output="/tmp/czkawka_${scan_type}_$(date +%s).txt"
    
    echo "Scanning for duplicate $scan_type..."
    
    case $scan_type in
        images)
            czkawka_cli image --directories "$TARGET_DIR" > "$temp_output"
            ;;
        videos)
            czkawka_cli video --directories "$TARGET_DIR" > "$temp_output"
            ;;
        music)
            czkawka_cli music --directories "$TARGET_DIR" > "$temp_output"
            ;;
        documents)
            # For documents, we'll use same_music but with document extensions
            # or duplicate finder which works with all file types
            czkawka_cli dup --directories "$TARGET_DIR" --allowed-extensions pdf,doc,docx,txt,rtf,odt,xls,xlsx,ppt,pptx,epub > "$temp_output"
            ;;
        archives)
            czkawka_cli dup --directories "$TARGET_DIR" --allowed-extensions zip,rar,7z,tar,gz,bz2,xz > "$temp_output"
            ;;
        general)
            czkawka_cli dup --directories "$TARGET_DIR" > "$temp_output"
            ;;
    esac
    
    # Append to main output file
    if [ -s "$temp_output" ]; then
        echo "=== $scan_type duplicates ===" >> "$SCAN_OUTPUT"
        cat "$temp_output" >> "$SCAN_OUTPUT"
        echo >> "$SCAN_OUTPUT"
    fi
    
    rm -f "$temp_output"
}

# --- Run scans based on selected types ---
> "$SCAN_OUTPUT"  # Clear the output file

if [ "$SCAN_TYPES" = "all" ]; then
    run_scan "images"
    run_scan "videos" 
    run_scan "music"
    run_scan "documents"
    run_scan "archives"
    # Also run general duplicate scan for any other files
    echo "Scanning for other duplicate files..."
    czkawka_cli duplicate --directories "$TARGET_DIR" >> "$SCAN_OUTPUT"
else
    run_scan "$SCAN_TYPES"
fi

# Check if any duplicates were found
if [ ! -s "$SCAN_OUTPUT" ]; then
    echo "No duplicates found!"
    rm -f "$SCAN_OUTPUT"
    exit 0
fi

echo
echo "Processing duplicates..."

# --- Function to process duplicates ---
process_duplicates() {
    local inside_group=false
    local file_count=0
    local total_moved=0
    local total_kept=0

    while IFS= read -r line; do
        # Skip section headers
        if [[ "$line" =~ ^=== ]]; then
            continue
        fi
        
        # Detect start of a new group
        if [[ "$line" =~ ^Group ]] || [[ "$line" =~ ^Found ]]; then
            inside_group=true
            file_count=0
            continue
        fi

        # Skip empty lines
        if [[ -z "$line" ]]; then
            inside_group=false
            continue
        fi

        # Process files in a group
        if $inside_group; then
            # Extract file path by removing everything after the first " - " pattern
            # This handles formats like: "/path/file.jpg" - 945x2048 - 62.91 KiB - Original
            file_path=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/ - .*$//')
            
            # Remove quotes if present
            file_path=$(echo "$file_path" | sed 's/^"//;s/"$//')

            if [ $file_count -eq 0 ]; then
                echo "Keeping: $file_path"
                ((total_kept++))
            else
                if [ -f "$file_path" ]; then
                    echo "Moving duplicate: $file_path"
                    
                    # Create subdirectory structure in duplicates folder to avoid name conflicts
                    rel_path=$(realpath --relative-to="$TARGET_DIR" "$file_path")
                    dest_dir="$DUPLICATES_DIR/$(dirname "$rel_path")"
                    mkdir -p "$dest_dir"
                    
                    # Move the file
                    if mv "$file_path" "$dest_dir/"; then
                        ((total_moved++))
                    else
                        echo "Error: Failed to move $file_path"
                    fi
                else
                    echo "Warning: File not found - $file_path"
                fi
            fi

            ((file_count++))
        fi
    done < "$SCAN_OUTPUT"
    
    echo
    echo "=== Summary ==="
    echo "Files kept: $total_kept"
    echo "Files moved: $total_moved" 
    echo "Duplicates moved to: $DUPLICATES_DIR"
}

# Process the duplicates
process_duplicates

# Cleanup
rm -f "$SCAN_OUTPUT"

echo
echo "Done! All duplicates have been processed."