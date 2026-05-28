#!/bin/bash

# Advanced Duplicate File Remover using External Tools
# Supports multiple tools: fdupes, rdfind, dupe-krill, and fclones
# With rollback support and state management

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"00
STATE_DIR="$SCRIPT_DIR/.duplicate_state"
QUARANTINE_DIR="$STATE_DIR/quarantine"
SCAN_RESULTS="$STATE_DIR/duplicates.txt"
REMOVAL_LOG="$STATE_DIR/removal_log.json"
CONFIG_FILE="$STATE_DIR/config.conf"

# Default configuration
DEFAULT_TOOL="fdupes"
DEFAULT_MIN_SIZE="1M"
DEFAULT_EXTENSIONS="jpg,jpeg,png,gif,bmp,tiff,webp,mp4,avi,mkv,mov,wmv,flv,mp3,wav,pdf,doc,docx,xls,xlsx,ppt,pptx,txt,zip,rar"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Initialize directories and config
init_setup() {
    mkdir -p "$STATE_DIR" "$QUARANTINE_DIR"
    
    # Create default config if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# Duplicate Remover Configuration
TOOL=$DEFAULT_TOOL
MIN_SIZE=$DEFAULT_MIN_SIZE
EXTENSIONS=$DEFAULT_EXTENSIONS
KEEP_POLICY=oldest
EXCLUDE_PATHS=""
EOF
    fi
    source "$CONFIG_FILE"
}

# Print colored output
print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_progress() { echo -e "${BLUE}[PROGRESS]${NC} $1"; }
print_tool() { echo -e "${CYAN}[TOOL]${NC} $1"; }

# Check if tool is installed
check_tool() {
    local tool="$1"
    command -v "$tool" &> /dev/null
}

# Install tools with instructions
install_tools() {
    local tool="${1:-all}"
    
    echo -e "${CYAN}=== INSTALLATION INSTRUCTIONS ===${NC}"
    echo
    
    case "$tool" in
        "fdupes"|"all")
            echo -e "${GREEN}1. FDUPES${NC} - Fast and reliable duplicate finder"
            echo "   Installation:"
            echo "   sudo apt update && sudo apt install fdupes"
            echo "   Features: Fast, simple, widely available"
            echo
            ;;
    esac
    
    case "$tool" in
        "rdfind"|"all")
            echo -e "${GREEN}2. RDFIND${NC} - Advanced duplicate finder with ranking"
            echo "   Installation:"
            echo "   sudo apt update && sudo apt install rdfind"
            echo "   Features: Intelligent file ranking, handles symlinks"
            echo
            ;;
    esac
    
    case "$tool" in
        "dupe-krill"|"all")
            echo -e "${GREEN}3. DUPE-KRILL${NC} - Modern Rust-based duplicate finder"
            echo "   Installation:"
            echo "   # Method 1: Using Cargo (Rust package manager)"
            echo "   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            echo "   source ~/.cargo/env"
            echo "   cargo install dupe-krill"
            echo
            echo "   # Method 2: Download binary from GitHub"
            echo "   wget https://github.com/kornelski/dupe-krill/releases/latest/download/dupe-krill-linux.tar.gz"
            echo "   tar -xzf dupe-krill-linux.tar.gz"
            echo "   sudo mv dupe-krill /usr/local/bin/"
            echo "   Features: Very fast, modern, good for large datasets"
            echo
            ;;
    esac
    
    case "$tool" in
        "fclones"|"all")
            echo -e "${GREEN}4. FCLONES${NC} - High-performance duplicate finder"
            echo "   Installation:"
            echo "   # Method 1: Using Cargo"
            echo "   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            echo "   source ~/.cargo/env"
            echo "   cargo install fclones"
            echo
            echo "   # Method 2: Download binary"
            echo "   wget https://github.com/pkolaczk/fclones/releases/latest/download/fclones-0.34.0-linux-musl-x86_64.tar.gz"
            echo "   tar -xzf fclones-*-linux-musl-x86_64.tar.gz"
            echo "   sudo mv fclones /usr/local/bin/"
            echo "   Features: Extremely fast, advanced filtering, JSON output"
            echo
            ;;
    esac
    
    case "$tool" in
        "jdupes"|"all")
            echo -e "${GREEN}5. JDUPES${NC} - Enhanced fdupes fork"
            echo "   Installation:"
            echo "   # Method 1: From source"
            echo "   git clone https://github.com/jbruchon/jdupes.git"
            echo "   cd jdupes && make && sudo make install"
            echo
            echo "   # Method 2: Some distributions have it in repos"
            echo "   sudo apt update && sudo apt install jdupes  # (if available)"
            echo "   Features: Enhanced fdupes with better performance"
            echo
            ;;
    esac
    
    if [ "$tool" = "all" ]; then
        echo -e "${YELLOW}RECOMMENDED SETUP:${NC}"
        echo "1. Start with fdupes (easiest): sudo apt install fdupes"
        echo "2. For better performance, try fclones or dupe-krill"
        echo "3. Use rdfind for advanced duplicate handling"
        echo
        echo "After installation, run: $0 check-tools"
    fi
}

# Check available tools
check_tools() {
    local tools=("fdupes" "rdfind" "dupe-krill" "fclones" "jdupes")
    local available=()
    local missing=()
    
    echo -e "${CYAN}=== TOOL AVAILABILITY CHECK ===${NC}"
    
    for tool in "${tools[@]}"; do
        if check_tool "$tool"; then
            available+=("$tool")
            local version
            case "$tool" in
                "fdupes"|"jdupes") version=$($tool --version 2>/dev/null | head -1 || echo "unknown") ;;
                "rdfind") version=$($tool --version 2>/dev/null | head -1 || echo "unknown") ;;
                "dupe-krill") version=$($tool --version 2>/dev/null || echo "unknown") ;;
                "fclones") version=$($tool --version 2>/dev/null || echo "unknown") ;;
            esac
            echo -e "  ${GREEN}✓${NC} $tool - $version"
        else
            missing+=("$tool")
            echo -e "  ${RED}✗${NC} $tool - not installed"
        fi
    done
    
    echo
    if [ ${#available[@]} -gt 0 ]; then
        echo -e "${GREEN}Available tools:${NC} ${available[*]}"
        echo "Current configured tool: $TOOL"
    else
        echo -e "${RED}No duplicate finder tools are installed!${NC}"
        echo "Run: $0 install"
        return 1
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing tools:${NC} ${missing[*]}"
        echo "To install specific tool: $0 install <tool-name>"
    fi
}

# Build file filter arguments
build_file_filter() {
    local tool="$1"
    local target_dir="$2"
    local filter_args=""
    
    # Size filter
    case "$tool" in
        "fdupes"|"jdupes")
            if [ "$MIN_SIZE" != "0" ]; then
                filter_args="$filter_args --size=+${MIN_SIZE}"
            fi
            ;;
        "rdfind")
            if [ "$MIN_SIZE" != "0" ]; then
                filter_args="$filter_args -minsize ${MIN_SIZE//[^0-9]/}"
            fi
            ;;
        "fclones")
            if [ "$MIN_SIZE" != "0" ]; then
                filter_args="$filter_args --min-size ${MIN_SIZE}"
            fi
            ;;
    esac
    
    # Extension filter (create temporary script for complex filtering)
    if [ -n "$EXTENSIONS" ]; then
        local temp_script="$STATE_DIR/filter_files.sh"
        cat > "$temp_script" << 'EOF'
#!/bin/bash
find "$1" -type f \( -name "*.${2//,/*" -o -name "*.}" \) 2>/dev/null
EOF
        chmod +x "$temp_script"
    fi
    
    echo "$filter_args"
}

# Scan using fdupes
scan_with_fdupes() {
    local target_dir="$1"
    local tool="${2:-fdupes}"
    
    print_tool "Using $tool to scan: $target_dir"
    
    local cmd="$tool --recurse --size --time"
    
    # Add size filter if specified
    if [ "$MIN_SIZE" != "0" ]; then
        cmd="$cmd --size=+${MIN_SIZE}"
    fi
    
    # Add sameline for easier parsing
    if [ "$tool" = "jdupes" ]; then
        cmd="$cmd --print-summarized"
    fi
    
    print_progress "Scanning for duplicates..."
    if $cmd "$target_dir" > "$SCAN_RESULTS" 2>/dev/null; then
        local groups
        groups=$(grep -c "^$" "$SCAN_RESULTS" 2>/dev/null || echo "0")
        print_status "Scan complete! Found approximately $groups duplicate groups"
        return 0
    else
        print_error "Scan failed with $tool"
        return 1
    fi
}

# Scan using rdfind
scan_with_rdfind() {
    local target_dir="$1"
    
    print_tool "Using rdfind to scan: $target_dir"
    
    local temp_output="$STATE_DIR/rdfind_output.txt"
    local cmd="rdfind -makesymlinks false -makeresultsfile true"
    
    # Add size filter
    if [ "$MIN_SIZE" != "0" ]; then
        local size_bytes
        size_bytes=$(echo "$MIN_SIZE" | sed 's/[^0-9]*//g')
        case "$MIN_SIZE" in
            *K|*k) size_bytes=$((size_bytes * 1024)) ;;
            *M|*m) size_bytes=$((size_bytes * 1024 * 1024)) ;;
            *G|*g) size_bytes=$((size_bytes * 1024 * 1024 * 1024)) ;;
        esac
        cmd="$cmd -minsize $size_bytes"
    fi
    
    print_progress "Scanning for duplicates..."
    if $cmd "$target_dir" > "$temp_output" 2>&1; then
        # Convert rdfind output to our format
        if [ -f "results.txt" ]; then
            grep "DUPTYPE_FIRST_OCCURRENCE\|DUPTYPE_WITHIN_SAME_TREE" results.txt > "$SCAN_RESULTS"
            rm -f results.txt
            local count
            count=$(wc -l < "$SCAN_RESULTS")
            print_status "Scan complete! Found $count duplicate files"
            return 0
        fi
    fi
    
    print_error "Scan failed with rdfind"
    return 1
}

# Scan using fclones
scan_with_fclones() {
    local target_dir="$1"
    
    print_tool "Using fclones to scan: $target_dir"
    
    local cmd="fclones group --format fdupes"
    
    # Add size filter
    if [ "$MIN_SIZE" != "0" ]; then
        cmd="$cmd --min-size $MIN_SIZE"
    fi
    
    # Add extension filter
    if [ -n "$EXTENSIONS" ]; then
        IFS=',' read -ra EXTS <<< "$EXTENSIONS"
        for ext in "${EXTS[@]}"; do
            cmd="$cmd --name '*.${ext}'"
        done
    fi
    
    print_progress "Scanning for duplicates..."
    if eval "$cmd \"$target_dir\"" > "$SCAN_RESULTS" 2>/dev/null; then
        local groups
        groups=$(grep -c "^$" "$SCAN_RESULTS" 2>/dev/null || echo "0")
        print_status "Scan complete! Found $groups duplicate groups"
        return 0
    else
        print_error "Scan failed with fclones"
        return 1
    fi
}

# Scan using dupe-krill
scan_with_dupe_krill() {
    local target_dir="$1"
    
    print_tool "Using dupe-krill to scan: $target_dir"
    
    local temp_output="$STATE_DIR/dupe_krill_output.txt"
    
    print_progress "Scanning for duplicates..."
    if dupe-krill --dir "$target_dir" > "$temp_output" 2>&1; then
        # Convert dupe-krill output to fdupes format
        awk '/^Duplicate/ { getline; while(getline && $0 !~ /^$/) print; print "" }' "$temp_output" > "$SCAN_RESULTS"
        local groups
        groups=$(grep -c "^$" "$SCAN_RESULTS" 2>/dev/null || echo "0")
        print_status "Scan complete! Found $groups duplicate groups"
        return 0
    else
        print_error "Scan failed with dupe-krill"
        return 1
    fi
}

# Main scan function
scan_duplicates() {
    local target_dir="$1"
    local resume="${2:-false}"
    
    if [ ! -d "$target_dir" ]; then
        print_error "Directory not found: $target_dir"
        return 1
    fi
    
    # Check if tool is available
    if ! check_tool "$TOOL"; then
        print_error "Tool '$TOOL' is not installed"
        echo "Available tools:"
        check_tools
        echo
        echo "To install tools: $0 install"
        return 1
    fi
    
    # Skip scan if resuming and results exist
    if [ "$resume" = "true" ] && [ -f "$SCAN_RESULTS" ] && [ -s "$SCAN_RESULTS" ]; then
        print_status "Resuming with existing scan results"
        return 0
    fi
    
    # Run appropriate scanner
    case "$TOOL" in
        "fdupes"|"jdupes") scan_with_fdupes "$target_dir" "$TOOL" ;;
        "rdfind") scan_with_rdfind "$target_dir" ;;
        "fclones") scan_with_fclones "$target_dir" ;;
        "dupe-krill") scan_with_dupe_krill "$target_dir" ;;
        *) 
            print_error "Unsupported tool: $TOOL"
            return 1
            ;;
    esac
}

# Show duplicates
show_duplicates() {
    if [ ! -f "$SCAN_RESULTS" ] || [ ! -s "$SCAN_RESULTS" ]; then
        print_error "No scan results found. Run scan first."
        return 1
    fi
    
    print_status "Duplicate groups found:"
    echo
    
    local group_num=1
    local current_group=""
    local file_count=0
    
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$current_group" ]; then
                echo -e "${CYAN}Group $group_num:${NC}"
                echo "$current_group" | nl -w2 -s'. '
                echo
                group_num=$((group_num + 1))
                current_group=""
                file_count=0
            fi
        else
            current_group="$current_group$line\n"
            file_count=$((file_count + 1))
        fi
    done < "$SCAN_RESULTS"
    
    # Handle last group if file doesn't end with empty line
    if [ -n "$current_group" ]; then
        echo -e "${CYAN}Group $group_num:${NC}"
        echo -e "$current_group" | nl -w2 -s'. '
    fi
}

# Remove duplicates with quarantine
remove_duplicates() {
    local dry_run="${1:-false}"
    
    if [ ! -f "$SCAN_RESULTS" ] || [ ! -s "$SCAN_RESULTS" ]; then
        print_error "No scan results found. Run scan first."
        return 1
    fi
    
    if [ "$dry_run" = "true" ]; then
        print_status "DRY RUN - No files will be moved"
    else
        print_status "Moving duplicate files to quarantine..."
    fi
    
    # Initialize removal log
    echo '[]' > "$REMOVAL_LOG"
    
    local removed_count=0
    local saved_space=0
    local current_group=""
    local group_files=()
    
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            # Process complete group
            if [ ${#group_files[@]} -gt 1 ]; then
                # Keep first file (or apply keep policy)
                local keep_index=0
                if [ "$KEEP_POLICY" = "newest" ]; then
                    # Find newest file
                    local newest_time=0
                    for i in "${!group_files[@]}"; do
                        local file_time
                        file_time=$(stat -c%Y "${group_files[$i]}" 2>/dev/null || echo "0")
                        if [ "$file_time" -gt "$newest_time" ]; then
                            newest_time="$file_time"
                            keep_index=$i
                        fi
                    done
                fi
                
                # Remove all files except the one we're keeping
                for i in "${!group_files[@]}"; do
                    if [ $i -ne $keep_index ]; then
                        local file="${group_files[$i]}"
                        if [ -f "$file" ]; then
                            local file_size
                            file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
                            
                            if [ "$dry_run" = "false" ]; then
                                # Create quarantine path
                                local rel_path="${file#/}"
                                local quarantine_path="$QUARANTINE_DIR/$rel_path"
                                local quarantine_dir
                                quarantine_dir=$(dirname "$quarantine_path")
                                
                                mkdir -p "$quarantine_dir"
                                
                                # Move file to quarantine
                                if mv "$file" "$quarantine_path"; then
                                    # Log the removal
                                    local log_entry
                                    log_entry=$(jq -n \
                                        --arg original "$file" \
                                        --arg quarantine "$quarantine_path" \
                                        --arg size "$file_size" \
                                        --arg timestamp "$(date -Iseconds)" \
                                        '{original: $original, quarantine: $quarantine, size: ($size | tonumber), timestamp: $timestamp}')
                                    
                                    jq --argjson entry "$log_entry" '. += [$entry]' "$REMOVAL_LOG" > "$REMOVAL_LOG.tmp"
                                    mv "$REMOVAL_LOG.tmp" "$REMOVAL_LOG"
                                    
                                    print_status "Moved: $file"
                                else
                                    print_error "Failed to move: $file"
                                    continue
                                fi
                            else
                                print_status "Would move: $file"
                            fi
                            
                            removed_count=$((removed_count + 1))
                            saved_space=$((saved_space + file_size))
                        fi
                    fi
                done
            fi
            group_files=()
        else
            group_files+=("$line")
        fi
    done < "$SCAN_RESULTS"
    
    # Handle last group if no trailing empty line
    if [ ${#group_files[@]} -gt 1 ]; then
        # Same processing logic as above...
        local keep_index=0
        if [ "$KEEP_POLICY" = "newest" ]; then
            local newest_time=0
            for i in "${!group_files[@]}"; do
                local file_time
                file_time=$(stat -c%Y "${group_files[$i]}" 2>/dev/null || echo "0")
                if [ "$file_time" -gt "$newest_time" ]; then
                    newest_time="$file_time"
                    keep_index=$i
                fi
            done
        fi
        
        for i in "${!group_files[@]}"; do
            if [ $i -ne $keep_index ]; then
                local file="${group_files[$i]}"
                if [ -f "$file" ]; then
                    local file_size
                    file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
                    
                    if [ "$dry_run" = "false" ]; then
                        local rel_path="${file#/}"
                        local quarantine_path="$QUARANTINE_DIR/$rel_path"
                        local quarantine_dir
                        quarantine_dir=$(dirname "$quarantine_path")
                        
                        mkdir -p "$quarantine_dir"
                        
                        if mv "$file" "$quarantine_path"; then
                            local log_entry
                            log_entry=$(jq -n \
                                --arg original "$file" \
                                --arg quarantine "$quarantine_path" \
                                --arg size "$file_size" \
                                --arg timestamp "$(date -Iseconds)" \
                                '{original: $original, quarantine: $quarantine, size: ($size | tonumber), timestamp: $timestamp}')
                            
                            jq --argjson entry "$log_entry" '. += [$entry]' "$REMOVAL_LOG" > "$REMOVAL_LOG.tmp"
                            mv "$REMOVAL_LOG.tmp" "$REMOVAL_LOG"
                            
                            print_status "Moved: $file"
                        else
                            print_error "Failed to move: $file"
                            continue
                        fi
                    else
                        print_status "Would move: $file"
                    fi
                    
                    removed_count=$((removed_count + 1))
                    saved_space=$((saved_space + file_size))
                fi
            fi
        done
    fi
    
    local saved_mb=$((saved_space / 1024 / 1024))
    print_status "Operation complete!"
    print_status "Files processed: $removed_count"
    print_status "Space that would be saved: ${saved_mb}MB"
}

# Rollback function
rollback() {
    if [ ! -f "$REMOVAL_LOG" ]; then
        print_error "No removal log found. Nothing to rollback."
        return 1
    fi
    
    local total_files
    total_files=$(jq 'length' "$REMOVAL_LOG")
    
    if [ "$total_files" -eq 0 ]; then
        print_status "No files to rollback."
        return 0
    fi
    
    print_status "Rolling back $total_files files..."
    
    local restored_count=0
    
    while read -r entry; do
        local original_path quarantine_path
        original_path=$(echo "$entry" | jq -r '.original')
        quarantine_path=$(echo "$entry" | jq -r '.quarantine')
        
        if [ ! -f "$quarantine_path" ]; then
            print_warning "Quarantined file not found: $quarantine_path"
            continue
        fi
        
        # Create original directory if needed
        local original_dir
        original_dir=$(dirname "$original_path")
        mkdir -p "$original_dir"
        
        # Restore file
        if mv "$quarantine_path" "$original_path"; then
            print_status "Restored: $original_path"
            restored_count=$((restored_count + 1))
        else
            print_error "Failed to restore: $original_path"
        fi
        
    done < <(jq -c '.[]' "$REMOVAL_LOG")
    
    # Clear logs after successful rollback
    echo '[]' > "$REMOVAL_LOG"
    
    print_status "Rollback complete! Restored $restored_count files."
}

# Clean quarantine
clean_quarantine() {
    if [ ! -d "$QUARANTINE_DIR" ] || [ -z "$(ls -A "$QUARANTINE_DIR" 2>/dev/null)" ]; then
        print_status "Quarantine is empty."
        return 0
    fi
    
    local file_count
    file_count=$(find "$QUARANTINE_DIR" -type f | wc -l)
    local size
    size=$(du -sh "$QUARANTINE_DIR" 2>/dev/null | cut -f1)
    
    echo -e "${RED}WARNING: This will permanently delete $file_count files ($size) from quarantine!${NC}"
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" = "yes" ]; then
        rm -rf "$QUARANTINE_DIR"/*
        echo '[]' > "$REMOVAL_LOG"
        print_status "Quarantine cleaned successfully."
    else
        print_status "Operation cancelled."
    fi
}

# Configure tool settings
configure() {
    echo -e "${CYAN}=== CONFIGURATION ===${NC}"
    echo
    
    # Check available tools
    local available_tools=()
    for tool in "fdupes" "jdupes" "rdfind" "fclones" "dupe-krill"; do
        if check_tool "$tool"; then
            available_tools+=("$tool")
        fi
    done
    
    if [ ${#available_tools[@]} -eq 0 ]; then
        print_error "No duplicate finder tools available. Run: $0 install"
        return 1
    fi
    
    echo "Available tools: ${available_tools[*]}"
    echo "Current tool: $TOOL"
    read -p "Select tool [${available_tools[0]}]: " new_tool
    new_tool=${new_tool:-${available_tools[0]}}
    
    echo "Current minimum size: $MIN_SIZE"
    read -p "Minimum file size (e.g., 1M, 500K, 0 for all) [$MIN_SIZE]: " new_size
    new_size=${new_size:-$MIN_SIZE}
    
    echo "Current keep policy: $KEEP_POLICY"
    read -p "Keep policy (oldest/newest) [$KEEP_POLICY]: " new_policy
    new_policy=${new_policy:-$KEEP_POLICY}
    
    # Update config file
    cat > "$CONFIG_FILE" << EOF
# Duplicate Remover Configuration
TOOL=$new_tool
MIN_SIZE=$new_size
EXTENSIONS=$EXTENSIONS
KEEP_POLICY=$new_policy
EXCLUDE_PATHS="$EXCLUDE_PATHS"
EOF
    
    print_status "Configuration updated!"
    print_status "Tool: $new_tool"
    print_status "Min size: $new_size"
    print_status "Keep policy: $new_policy"
}

# Show status
show_status() {
    print_status "Duplicate Remover Status:"
    echo
    
    echo "  Current Tool: $TOOL"
    echo "  Min File Size: $MIN_SIZE"
    echo "  Keep Policy: $KEEP_POLICY"
    echo
    
    if [ -f "$SCAN_RESULTS" ] && [ -s "$SCAN_RESULTS" ]; then
        local groups
        groups=$(grep -c "^$" "$SCAN_RESULTS" 2>/dev/null || echo "0")
        groups=$((groups + 1)) # Add one for last group if no trailing empty line
        echo "  Scan Results: $groups duplicate groups found"
    else
        echo "  Scan Results: No scan performed yet"
    fi
    
    if [ -f "$REMOVAL_LOG" ]; then
        local removed
        removed=$(jq 'length' "$REMOVAL_LOG")
        echo "  Removed Files: $removed files in quarantine"
    else
        echo "  Removed Files: None"
    fi
    
    if [ -d "$QUARANTINE_DIR" ]; then
        local quarantine_size
        quarantine_size=$(du -sh "$QUARANTINE_DIR" 2>/dev/null | cut -f1 || echo "0")
        echo "  Quarantine Size: $quarantine_size"
    fi
    
    echo "  State Directory: $STATE_DIR"
}

# Usage information
usage() {
    cat << EOF
Advanced Duplicate File Remover using External Tools

Usage: $0 <command> [options]

Setup Commands:
    install [tool]       Show installation instructions for tools
    check-tools          Check which tools are available
    configure            Configure tool settings

Scanning Commands:
    scan <directory>     Scan directory for duplicates
    resume <directory>   Resume with existing scan results
    show                 Show found duplicates

Action Commands:
    remove              Remove duplicates (move to quarantine)
    dry-run             Show what would be removed (no changes)
    rollback            Restore all files from quarantine
    clean               Permanently delete quarantined files

Info Commands:
    status              Show current status
    help                Show this help message

Supported Tools:
    fdupes      - Fast, simple, widely available
    jdupes      - Enhanced fdupes with better performance  
    rdfind      - Advanced with intelligent file ranking
    fclones     - High-performance Rust-based tool
    dupe-krill  - Modern Rust tool for large datasets

Examples:
    $0 install                    # Show installation instructions
    $0 check-tools               # Check available tools
    $0 configure                 # Configure settings
    $0 scan /media/ntfs-drive    # Scan for duplicates
    $0 show                      # Show results
    $0 dry-run                   # Preview changes
    $0 remove                    # Remove duplicates
    $0 rollback                  # Restore files

State files are stored in: $STATE_DIR
EOF
}

# Main function
main() {
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    init_setup
    
    case "$1" in
        install)
            install_tools "${2:-all}"
            ;;
        check-tools)
            check_tools
            ;;
        configure)
            configure
            ;;
        scan)
            if [ $# -ne 2 ]; then
                print_error "Usage: $0 scan <directory>"
                exit 1
            fi
            if [ ! -d "$2" ]; then
                print_error "Directory not found: $2"
                exit 1
            fi
            scan_duplicates "$2"
            ;;
        resume)
            if [ $# -ne 2 ]; then
                print_error "Usage: $0 resume <directory>"
                exit 1
            fi
            if [ ! -d "$2" ]; then
                print_error "Directory not found: $2"
                exit 1
            fi
            scan_duplicates "$2" true
            ;;
        show)
            show_duplicates
            ;;
        remove)
            remove_duplicates
            ;;
        dry-run)
            remove_duplicates true
            ;;
        rollback)
            rollback
            ;;
        clean)
            clean_quarantine
            ;;
        status)
            show_status
            ;;
        help)
            usage
            ;;
        *)
            print_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"