#!/bin/bash
# ext4-dedupe.sh - Safe deduplication script for ext4 filesystems

set -euo pipefail

# Configuration
LOG_FILE="/var/log/ext4-dedupe.log"
HASH_FILE="/var/lib/duperemove/ext4.hash"
BACKUP_DIR="/tmp/dedupe-backup-$(date +%Y%m%d)"
DRY_RUN=${1:-false}
DUPE_TOOL=""  # Will be set in check_prerequisites

# Directories to deduplicate (customize as needed)
DEDUPE_DIRS=(
    "/media/ayoub/data/private/phone_backups"
)

# Exclude patterns (files to skip)
EXCLUDE_PATTERNS=(
    "*.log"
    "*.tmp"
    "/proc/*"
    "/sys/*"
    "/dev/*"
    "/run/*"
)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
    
    # Check available tools - prefer fdupes over jdupes due to safety restrictions
    if command -v fdupes >/dev/null 2>&1; then
        DUPE_TOOL="fdupes"
        log "Using fdupes for duplicate detection"
    elif command -v rdfind >/dev/null 2>&1; then
        DUPE_TOOL="rdfind"
        log "Using rdfind for duplicate detection"
    elif command -v jdupes >/dev/null 2>&1; then
        DUPE_TOOL="jdupes"
        log "Using jdupes for duplicate detection (may have limitations)"
    else
        error_exit "No duplicate detection tool found. Install fdupes, rdfind, or jdupes"
    fi
    
    # Check duperemove
    command -v duperemove >/dev/null 2>&1 || error_exit "duperemove not installed"
    
    # Check filesystem type
    local fs_type=$(df -T / | tail -1 | awk '{print $2}')
    log "Root filesystem type: $fs_type"
    
    # Create necessary directories
    mkdir -p "$(dirname "$HASH_FILE")"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log "Prerequisites check completed"
}

create_backup_list() {
    log "Creating backup list of important files..."
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # List critical system files
    find /etc -type f -name "*.conf" -o -name "*.cfg" > "$BACKUP_DIR/config-files.list" 2>/dev/null || true
    
    # Backup package list
    dpkg --get-selections > "$BACKUP_DIR/package-list.txt" 2>/dev/null || true
    
    log "Backup list created in $BACKUP_DIR"
}

analyze_duplicates() {
    log "Analyzing filesystem for duplicates using $DUPE_TOOL..."
    
    for dir in "${DEDUPE_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            log "Analyzing directory: $dir"
            
            # Create safe filename for temporary file
            local safe_dir=$(echo "$dir" | sed 's|/|_|g')
            local temp_file="/tmp/dupe-analysis-${safe_dir}.txt"
            
            case "$DUPE_TOOL" in
                "fdupes")
                    log "Running fdupes analysis..."
                    if fdupes -r -S "$dir" > "$temp_file" 2>&1; then
                        if [[ -s "$temp_file" ]]; then
                            log "Fdupes analysis completed for $dir"
                            log "Summary:"
                            tail -10 "$temp_file" | tee -a "$LOG_FILE"
                            log "Example duplicates:"
                            head -20 "$temp_file" | tee -a "$LOG_FILE"
                        else
                            log "No duplicates found by fdupes in $dir"
                        fi
                    else
                        log "Error running fdupes on $dir"
                    fi
                    ;;
                "rdfind")
                    log "Running rdfind analysis..."
                    if rdfind -dryrun true "$dir" > "$temp_file" 2>&1; then
                        log "Rdfind analysis completed for $dir"
                        log "Results:"
                        grep -E "(duplicate|bytes)" "$temp_file" | head -20 | tee -a "$LOG_FILE"
                    else
                        log "Error running rdfind on $dir"
                    fi
                    ;;
                "jdupes")
                    log "Running jdupes directory scan..."
                    # Use directory mode since file specs are disabled
                    if jdupes -r -S "$dir" > "$temp_file" 2>&1; then
                        if [[ -s "$temp_file" ]]; then
                            log "Jdupes analysis completed for $dir"
                            tail -10 "$temp_file" | tee -a "$LOG_FILE"
                        else
                            log "No duplicates found by jdupes in $dir"
                        fi
                    else
                        log "Error running jdupes on $dir"
                        cat "$temp_file" | tee -a "$LOG_FILE"
                    fi
                    ;;
            esac
            
            # Always run the simple check as backup
            simple_duplicate_check "$dir"
            log "---"
        else
            log "Directory $dir does not exist, skipping"
        fi
    done
}

deduplicate_with_duperemove() {
    local target_dir="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would deduplicate $target_dir with duperemove"
        log "  Command would be: duperemove -dr --hashfile=$HASH_FILE $target_dir"
        
        # Show what files would be processed
        log "  Files that would be processed:"
        find "$target_dir" -type f -size +4k 2>/dev/null | head -10 | while read file; do
            log "    $file"
        done
        local file_count=$(find "$target_dir" -type f -size +4k 2>/dev/null | wc -l)
        log "  Total files to process: $file_count"
    else
        log "Deduplicating $target_dir with duperemove"
        
        # Build exclude arguments
        local exclude_args=""
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            exclude_args="$exclude_args --exclude=$pattern"
        done
        
        # Run duperemove (no dry-run flag as it's not supported)
        if duperemove -dr --hashfile="$HASH_FILE" $exclude_args "$target_dir" 2>&1 | tee -a "$LOG_FILE"; then
            log "Duperemove completed successfully for $target_dir"
        else
            log "WARNING: Duperemove reported issues for $target_dir"
        fi
    fi
}

deduplicate_with_hardlinks() {
    local target_dir="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would create hard links in $target_dir using $DUPE_TOOL"
        
        case "$DUPE_TOOL" in
            "fdupes")
                log "  Would run: fdupes -r -L $target_dir"
                fdupes -r "$target_dir" 2>/dev/null | head -10 | while read line; do
                    log "  Found: $line"
                done
                ;;
            "rdfind")
                log "  Would run: rdfind -makehardlinks true $target_dir"
                rdfind -dryrun true "$target_dir" 2>/dev/null | grep duplicate | head -5 | tee -a "$LOG_FILE"
                ;;
            "jdupes")
                log "  Would run: jdupes -r -L $target_dir (if file specs were enabled)"
                ;;
        esac
    else
        log "Creating hard links for duplicates in $target_dir using $DUPE_TOOL"
        
        case "$DUPE_TOOL" in
            "fdupes")
                if fdupes -r -L "$target_dir" 2>&1 | tee -a "$LOG_FILE"; then
                    log "Hard link creation with fdupes completed for $target_dir"
                else
                    log "WARNING: Hard link creation with fdupes reported issues for $target_dir"
                fi
                ;;
            "rdfind")
                if rdfind -makehardlinks true "$target_dir" 2>&1 | tee -a "$LOG_FILE"; then
                    log "Hard link creation with rdfind completed for $target_dir"
                else
                    log "WARNING: Hard link creation with rdfind reported issues for $target_dir"
                fi
                ;;
            *)
                log "Cannot create hard links with $DUPE_TOOL, skipping $target_dir"
                ;;
        esac
    fi
}

verify_filesystem() {
    log "Verifying filesystem integrity..."
    
    # Check filesystem
    if fsck -n /dev/$(df / | tail -1 | awk '{print $1}' | sed 's|/dev/||') 2>&1 | tee -a "$LOG_FILE"; then
        log "Filesystem check completed successfully"
    else
        log "WARNING: Filesystem check reported issues"
    fi
}

cleanup() {
    log "Cleaning up temporary files..."
    
    # Clean old hash files (older than 30 days)
    find "$(dirname "$HASH_FILE")" -name "*.hash" -mtime +30 -delete 2>/dev/null || true
    
    # Clean old backup directories (older than 7 days)
    find /tmp -name "dedupe-backup-*" -mtime +7 -type d -exec rm -rf {} + 2>/dev/null || true
    
    log "Cleanup completed"
}

show_results() {
    log "=== DEDUPLICATION RESULTS ==="
    
    # Show disk usage after deduplication
    log "Current disk usage:"
    df -h / | tee -a "$LOG_FILE"
    
    # Show largest directories
    log "Largest directories after deduplication:"
    du -sh "${DEDUPE_DIRS[@]}" 2>/dev/null | sort -hr | tee -a "$LOG_FILE"
    
    log "=== END RESULTS ==="
}

main() {
    log "Starting ext4 deduplication process..."
    log "Dry run mode: $DRY_RUN"
    
simple_duplicate_check() {
    local target_dir="$1"
    
    log "Running simple duplicate check for $target_dir"
    
    # Find files by size first (much faster)
    log "Finding files with identical sizes..."
    find "$target_dir" -type f -printf '%s %p\n' 2>/dev/null | \
        sort -n | \
        uniq -d -w 10 | \
        head -20 > "/tmp/same-size-files.txt"
    
    if [[ -s "/tmp/same-size-files.txt" ]]; then
        log "Files with identical sizes (potential duplicates):"
        cat "/tmp/same-size-files.txt" | tee -a "$LOG_FILE"
        
        # Count potential duplicates
        local count=$(wc -l < "/tmp/same-size-files.txt")
        log "Found $count files with identical sizes"
    else
        log "No files with identical sizes found"
    fi
    
    # Look for common duplicate patterns
    log "Looking for common backup/temporary file patterns..."
    find "$target_dir" -type f \( -name "*.bak" -o -name "*~" -o -name "*.tmp" -o -name "*.old" -o -name "Copy of *" -o -name "*copy*" \) 2>/dev/null | head -10 | tee -a "$LOG_FILE"
}
    
    # Process each directory
    for dir in "${DEDUPE_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            log "Processing directory: $dir"
            
            # Use duperemove for better performance on larger directories
            if [[ "$dir" == "/home" ]] || [[ "$dir" == "/opt" ]]; then
                deduplicate_with_duperemove "$dir"
            else
                # Use hard links for system directories (safer)
                deduplicate_with_hardlinks "$dir"
            fi
        fi
    done
    
    if [[ "$DRY_RUN" != "true" ]]; then
        verify_filesystem
    fi
    
    cleanup
    show_results
    
    log "Deduplication process completed!"
    log "Log file: $LOG_FILE"
    log "Backup information: $BACKUP_DIR"
}

# Handle script arguments
case "${1:-}" in
    --dry-run)
        DRY_RUN=true
        main
        ;;
    --help)
        echo "Usage: $0 [--dry-run|--help]"
        echo "  --dry-run  : Show what would be done without making changes"
        echo "  --help     : Show this help message"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac