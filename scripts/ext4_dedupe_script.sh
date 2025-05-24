#!/bin/bash
# ext4-dedupe.sh - Safe deduplication script for ext4 filesystems

set -euo pipefail

# Configuration
LOG_FILE="/var/log/ext4-dedupe.log"
HASH_FILE="/var/lib/duperemove/ext4.hash"
BACKUP_DIR="/tmp/dedupe-backup-$(date +%Y%m%d)"
DRY_RUN=${1:-false}

# Directories to deduplicate (customize as needed)
DEDUPE_DIRS=(
    "/home"
    "/var/cache"
    "/usr/share/doc"
    "/opt"
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
    
    # Check available tools
    command -v duperemove >/dev/null 2>&1 || error_exit "duperemove not installed"
    command -v jdupes >/dev/null 2>&1 || error_exit "jdupes not installed"
    
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
    log "Analyzing filesystem for duplicates..."
    
    for dir in "${DEDUPE_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            log "Analyzing directory: $dir"
            
            # Use jdupes for detailed analysis
            log "Running detailed duplicate analysis for $dir..."
            if jdupes -r -S "$dir" 2>/dev/null > "/tmp/jdupes-$dir-analysis.txt"; then
                # Extract summary information
                local summary=$(tail -10 "/tmp/jdupes-$dir-analysis.txt")
                log "Summary for $dir:"
                echo "$summary" | tee -a "$LOG_FILE"
                
                # Show some example duplicates
                log "Example duplicate files found in $dir:"
                jdupes -r "$dir" 2>/dev/null | head -20 | tee -a "$LOG_FILE"
                
                # Calculate potential space savings
                local total_wasted=$(grep "duplicate files" "/tmp/jdupes-$dir-analysis.txt" | grep -o '[0-9,]* bytes' | sed 's/,//g' | awk '{sum+=$1} END {print sum}')
                if [[ -n "$total_wasted" && "$total_wasted" -gt 0 ]]; then
                    local mb_wasted=$((total_wasted / 1024 / 1024))
                    log "Potential space savings in $dir: ${mb_wasted}MB"
                fi
            else
                log "Could not analyze $dir"
            fi
            
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
        log "DRY RUN: Would create hard links in $target_dir"
        jdupes -r "$target_dir" 2>/dev/null | head -20 | tee -a "$LOG_FILE"
    else
        log "Creating hard links for duplicates in $target_dir"
        
        # Create hard links for duplicates
        if jdupes -r -L "$target_dir" 2>&1 | tee -a "$LOG_FILE"; then
            log "Hard link creation completed for $target_dir"
        else
            log "WARNING: Hard link creation reported issues for $target_dir"
        fi
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
    
    check_prerequisites
    create_backup_list
    analyze_duplicates
    
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