#!/run/current-system/profile/bin/bash
# Setup config.txt for Raspberry Pi model
# Usage: ./setup-config.sh [pi3|pi4|pi5]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to show usage
show_usage() {
    echo "Usage: $0 [pi3|pi4|pi5]"
    echo ""
    echo "This script copies the appropriate config.txt template for your Raspberry Pi model."
    echo ""
    echo "Arguments:"
    echo "  pi3    - Raspberry Pi 3 (BCM2837, 1GB RAM)"
    echo "  pi4    - Raspberry Pi 4 (BCM2711, 2GB/4GB/8GB RAM)"
    echo "  pi5    - Raspberry Pi 5 (BCM2712, 4GB/8GB RAM)"
    echo ""
    echo "Examples:"
    echo "  $0 pi4    # Setup for Raspberry Pi 4"
    echo "  $0 pi5    # Setup for Raspberry Pi 5"
}

# Function to detect Pi model automatically
detect_pi_model() {
    if [ -f /proc/device-tree/model ]; then
        MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        case "$MODEL" in
            *"Raspberry Pi 3"*)
                echo "pi3"
                ;;
            *"Raspberry Pi 4"*)
                echo "pi4"
                ;;
            *"Raspberry Pi 5"*)
                echo "pi5"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    else
        echo "unknown"
    fi
}

# Function to copy config file
copy_config() {
    local model="$1"
    local source_file="$SCRIPT_DIR/config-${model}.txt"
    local target_file="/boot/config.txt"
    
    if [ ! -f "$source_file" ]; then
        print_error "Config template not found: $source_file"
        return 1
    fi
    
    if [ ! -d "/boot" ]; then
        print_error "Boot directory not found. Are you running this on a Raspberry Pi?"
        return 1
    fi
    
    # Backup existing config.txt if it exists
    if [ -f "$target_file" ]; then
        local backup_file="${target_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_status "Backing up existing config.txt to $backup_file"
        cp "$target_file" "$backup_file"
    fi
    
    # Copy new config
    print_status "Copying config for Raspberry Pi ${model^^}..."
    cp "$source_file" "$target_file"
    
    print_success "Config.txt updated for Raspberry Pi ${model^^}"
    print_status "You may need to reboot for changes to take effect"
}

# Main script logic
main() {
    local model=""
    
    # Check if model was provided as argument
    if [ $# -eq 1 ]; then
        case "$1" in
            pi3|pi4|pi5)
                model="$1"
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Invalid model: $1"
                show_usage
                exit 1
                ;;
        esac
    elif [ $# -eq 0 ]; then
        # Try to auto-detect
        print_status "No model specified, attempting to auto-detect..."
        model=$(detect_pi_model)
        
        if [ "$model" = "unknown" ]; then
            print_warning "Could not auto-detect Raspberry Pi model"
            echo ""
            show_usage
            exit 1
        else
            print_status "Detected Raspberry Pi model: ${model^^}"
        fi
    else
        print_error "Too many arguments"
        show_usage
        exit 1
    fi
    
    # Copy the appropriate config
    copy_config "$model"
}

# Run main function with all arguments
main "$@"
