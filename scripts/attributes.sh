#!/bin/bash

# File Attributes Demo Script
# Shows all available file attributes and metadata extraction methods

file_path="${1:-$(ls *.jpg *.jpeg *.png *.mp4 *.mov 2>/dev/null | head -1)}"

if [[ -z "$file_path" || ! -f "$file_path" ]]; then
    echo "Usage: $0 <file_path>"
    echo "Or run in a directory with image/video files"
    exit 1
fi

echo "==================================="
echo "FILE ATTRIBUTES FOR: $file_path"
echo "==================================="
echo

# 1. Basic stat command attributes
echo "1. BASIC STAT ATTRIBUTES:"
echo "------------------------"
stat "$file_path" 2>/dev/null || echo "stat command failed"
echo

# 2. Formatted stat attributes
echo "2. FORMATTED STAT ATTRIBUTES:"
echo "----------------------------"
echo "Access time:      $(stat -c %x "$file_path" 2>/dev/null)"
echo "Modify time:      $(stat -c %y "$file_path" 2>/dev/null)"  
echo "Change time:      $(stat -c %z "$file_path" 2>/dev/null)"
echo "Birth time:       $(stat -c %w "$file_path" 2>/dev/null)"
echo "Access timestamp: $(stat -c %X "$file_path" 2>/dev/null)"
echo "Modify timestamp: $(stat -c %Y "$file_path" 2>/dev/null)"
echo "Change timestamp: $(stat -c %Z "$file_path" 2>/dev/null)"
echo "Birth timestamp:  $(stat -c %W "$file_path" 2>/dev/null)"
echo

# 3. Check if exiftool is available
echo "3. EXIF METADATA (using exiftool):"
echo "----------------------------------"
if command -v exiftool >/dev/null 2>&1; then
    echo "EXIFTOOL AVAILABLE - Showing relevant date fields:"
    exiftool -time:all -s "$file_path" 2>/dev/null | head -20
    echo
    echo "All EXIF data preview (first 30 lines):"
    exiftool -s "$file_path" 2>/dev/null | head -30
else
    echo "exiftool NOT INSTALLED"
    echo "Install with: sudo apt-get install libimage-exiftool-perl"
    echo "Or: brew install exiftool (on macOS)"
fi
echo

# 4. Check if identify (ImageMagick) is available
echo "4. IMAGEMAGICK METADATA:"
echo "-----------------------"
if command -v identify >/dev/null 2>&1; then
    echo "IMAGEMAGICK AVAILABLE:"
    identify -verbose "$file_path" 2>/dev/null | grep -i date | head -10
else
    echo "ImageMagick NOT INSTALLED"
    echo "Install with: sudo apt-get install imagemagick"
fi
echo

# 5. Check if mediainfo is available (for videos)
echo "5. MEDIAINFO (for videos):"
echo "-------------------------"
if command -v mediainfo >/dev/null 2>&1; then
    echo "MEDIAINFO AVAILABLE:"
    mediainfo "$file_path" 2>/dev/null | grep -i date | head -10
else
    echo "mediainfo NOT INSTALLED"
    echo "Install with: sudo apt-get install mediainfo"
fi
echo

# 6. Check file command
echo "6. FILE COMMAND OUTPUT:"
echo "----------------------"
file "$file_path" 2>/dev/null
echo

# 7. Show ls timestamps
echo "7. LS COMMAND TIMESTAMPS:"
echo "------------------------"
echo "Default ls:    $(ls -l "$file_path")"
echo "Access time:   $(ls -lu "$file_path")"
echo "Change time:   $(ls -lc "$file_path")"
echo

echo "==================================="
echo "RECOMMENDED DATE EXTRACTION ORDER:"
echo "==================================="
echo "1. EXIF DateTimeOriginal (when photo was taken)"
echo "2. EXIF CreateDate"
echo "3. EXIF ModifyDate" 
echo "4. File modification time (stat -c %Y)"
echo "5. File birth time (stat -c %W) if available"
echo
echo "For videos:"
echo "1. MediaInfo creation date"