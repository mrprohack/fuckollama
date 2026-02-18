#!/bin/bash
#
# fuckollama - Ollama Instance Scanner
# Easy script to find publicly exposed Ollama instances
#
# Usage:
#   ./scan.sh [OPTIONS]
#   ./scan.sh --quick          # Quick test scan (small IP range)
#   ./scan.sh --full           # Full internet scan (requires root)
#   ./scan.sh --ip-file FILE   # Scan IPs from file
#
# Requirements:
#   - masscan (sudo apt install masscan)
#   - parallel (sudo apt install parallel)
#   - curl
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
PORT=11434
RATE=10000
TIMEOUT=300
OUTPUT_DIR="."
QUICK_RANGE="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Functions
print_banner() {
    echo -e "${RED}"
    echo "  _(_)_      w    c     e   t   t   e   r   s  "
    echo " (@@)        w    e    b    s   i   t   e   s  "
    echo "/-m-m-~~~~~~w~~~e~~~b~~~s~~~i~~~t~~~e~~~s~~~~~ "
    echo "${NC}"
    echo -e "${BLUE}Ollama Instance Scanner${NC}"
    echo "Find publicly exposed Ollama instances"
    echo ""
}

usage() {
    print_banner
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --quick           Quick scan (private IP ranges only)"
    echo "  --full            Full internet scan (requires root)"
    echo "  --rate NUM        Set scan rate (default: $RATE)"
    echo "  --port NUM        Set port (default: $PORT)"
    echo "  --timeout SEC     Timeout for masscan in seconds (default: $TIMEOUT)"
    echo "  --ip-file FILE    Scan IPs from file"
    echo "  --range RANGE     Custom IP range (CIDR)"
    echo "  --help            Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --quick                        # Quick local test"
    echo "  sudo $0 --full                    # Full scan (1hr, 100k pps)"
    echo "  sudo $0 --full --timeout 60       # Full scan 60s test"
    echo "  sudo $0 --range 0.0.0.0/0 --rate 100000 --timeout 60"
    echo "  $0 --ip-file ips.txt              # Check specific IPs"
    echo ""
    exit 0
}

check_deps() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v masscan &> /dev/null; then
        missing+=("masscan")
    fi
    
    if ! command -v parallel &> /dev/null; then
        missing+=("parallel")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

scan_range() {
    local range="$1"
    local output_file="$2"
    
    echo -e "${YELLOW}[*] Scanning range: $range${NC}"
    echo -e "${YELLOW}[*] Rate: $RATE packets/sec${NC}"
    echo -e "${YELLOW}[*] Port: $PORT${NC}"
    echo -e "${YELLOW}[*] Timeout: ${TIMEOUT}s${NC}"
    echo ""
    
    if [ "$range" = "0.0.0.0/0" ]; then
        if [ "$EUID" -ne 0 ]; then
            echo -e "${RED}[!] Full internet scan requires root${NC}"
            echo -e "${YELLOW}[*] Run with: sudo $0 --full${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}[*] Running: masscan -p$PORT $range --exclude 255.255.255.255 --rate=$RATE${NC}"
    echo -e "${GREEN}[*] Starting masscan...${NC}"
    echo -e "${YELLOW}[!] Tip: For full internet scan, use --rate 100000+ --timeout 3600+${NC}"
    
    local masscan_pid=""
    masscan -p$PORT "$range" \
        --exclude 255.255.255.255 \
        --rate=$RATE \
        -oB "$output_file.bin" \
        2>/dev/null &
    masscan_pid=$!
    
    local elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        if ! kill -0 $masscan_pid 2>/dev/null; then
            echo -e "${GREEN}[*] Masscan completed naturally${NC}"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        if [ $((elapsed % 10)) -eq 0 ]; then
            echo -e "${YELLOW}[*] Still scanning... ${elapsed}s / ${TIMEOUT}s${NC}"
        fi
    done
    
    if kill -0 $masscan_pid 2>/dev/null; then
        echo -e "${YELLOW}[*] Timeout reached (${TIMEOUT}s), stopping masscan...${NC}"
        kill $masscan_pid 2>/dev/null || true
        wait $masscan_pid 2>/dev/null || true
        echo -e "${GREEN}[*] Masscan stopped${NC}"
    fi
    
    if [ -f "$output_file.bin" ]; then
        masscan --readscan "$output_file.bin" -oX "$output_file.xml" 2>/dev/null || true
        
        if [ -f "$output_file.xml" ]; then
            grep -oP 'addr="[^"]+' "$output_file.xml" | cut -d'"' -f2 > "$output_file.ips"
            local ip_count=$(wc -l < "$output_file.ips")
            echo -e "${GREEN}[*] Found $ip_count IPs with port $PORT open${NC}"
        fi
    fi
}

check_ollama() {
    local ip="$1"
    local timeout=3
    
    response=$(curl -s --max-time "$timeout" "http://$ip:$PORT/api/tags" 2>/dev/null || echo "")
    
    if echo "$response" | grep -q '"models"'; then
        echo -e "${GREEN}[+] LIVE: $ip${NC}"
        echo "$ip" >> ollama_live.txt
        return 0
    else
        return 1
    fi
}

parallel_check() {
    local ip_file="$1"
    local threads=20
    
    if [ ! -f "$ip_file" ]; then
        echo -e "${RED}[!] IP file not found: $ip_file${NC}"
        exit 1
    fi
    
    local ip_count=$(wc -l < "$ip_file")
    echo -e "${YELLOW}[*] Checking $ip_count IPs with $threads parallel threads...${NC}"
    echo -e "${YELLOW}[*] This may take a while...${NC}"
    echo ""
    
    # Clear previous results
    > ollama_live.txt
    
    # Run parallel check
    parallel -j "$threads" \
        'curl -s --max-time 3 http://{}:'$PORT'/api/tags 2>/dev/null | grep -q "\"models\"" && echo {}' \
        :::: "$ip_file" \
        > ollama_live.txt 2>/dev/null || true
    
    local live_count=$(wc -l < ollama_live.txt)
    echo ""
    echo -e "${GREEN}[*] Found $live_count live Ollama instances${NC}"
    
    if [ "$live_count" -gt 0 ]; then
        echo -e "${GREEN}[*] Results saved to: ollama_live.txt${NC}"
        echo ""
        echo "Live IPs:"
        cat ollama_live.txt
    fi
}

# Main
main() {
    print_banner
    check_deps
    
    local mode="custom"
    local ip_file=""
    local custom_range=""
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --quick)
                mode="quick"
                shift
                ;;
            --full)
                mode="full"
                shift
                ;;
            --rate)
                RATE="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --port)
                PORT="$2"
                shift 2
                ;;
            --ip-file)
                ip_file="$2"
                mode="file"
                shift 2
                ;;
            --range)
                custom_range="$2"
                mode="custom"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done
    
    # Execute based on mode
    case "$mode" in
        quick)
            echo -e "${GREEN}[*] Quick scan mode (private ranges)${NC}"
            scan_range "$QUICK_RANGE" "scan_quick_${TIMESTAMP}"
            if [ -f "scan_quick_${TIMESTAMP}.ips" ]; then
                parallel_check "scan_quick_${TIMESTAMP}.ips"
            fi
            ;;
        full)
            echo -e "${GREEN}[*] Full internet scan mode${NC}"
            RATE=100000
            TIMEOUT=3600
            echo -e "${YELLOW}[*] Using aggressive settings: --rate $RATE --timeout $TIMEOUT${NC}"
            scan_range "0.0.0.0/0" "scan_full_${TIMESTAMP}"
            if [ -f "scan_full_${TIMESTAMP}.ips" ]; then
                parallel_check "scan_full_${TIMESTAMP}.ips"
            fi
            ;;
        file)
            if [ -z "$ip_file" ]; then
                echo -e "${RED}[!] Please specify IP file with --ip-file${NC}"
                exit 1
            fi
            echo -e "${GREEN}[*] Checking IPs from file: $ip_file${NC}"
            parallel_check "$ip_file"
            ;;
        custom)
            if [ -n "$custom_range" ]; then
                scan_range "$custom_range" "scan_custom_${TIMESTAMP}"
                if [ -f "scan_custom_${TIMESTAMP}.ips" ]; then
                    parallel_check "scan_custom_${TIMESTAMP}.ips"
                fi
            else
                echo -e "${YELLOW}[*] No scan mode specified${NC}"
                usage
            fi
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}[*] Done!${NC}"
}

main "$@"
