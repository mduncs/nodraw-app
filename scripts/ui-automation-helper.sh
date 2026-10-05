#!/bin/bash
#
# NoDraw UI Automation Helper
#
# Interactive tool for testing AppleScript UI automation commands.
# Useful for debugging and developing new test cases.
#
# Usage:
#   ./scripts/ui-automation-helper.sh              # Interactive mode
#   ./scripts/ui-automation-helper.sh list         # List UI elements
#   ./scripts/ui-automation-helper.sh key <key>    # Press a key
#   ./scripts/ui-automation-helper.sh cmd <key>    # Press Cmd+key
#   ./scripts/ui-automation-helper.sh code <code>  # Press key code
#   ./scripts/ui-automation-helper.sh activate     # Activate app
#   ./scripts/ui-automation-helper.sh windows      # Show window count
#

APP_NAME="NoDraw"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Run AppleScript and show result
run_script() {
    echo -e "${CYAN}Running AppleScript...${NC}"
    local result
    result=$(osascript -e "$1" 2>&1)
    local status=$?
    if [[ $status -eq 0 ]]; then
        echo -e "${GREEN}Success:${NC} $result"
    else
        echo -e "${RED}Error:${NC} $result"
    fi
    return $status
}

# Activate the app
cmd_activate() {
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        set frontmost to true
    end tell
end tell
"
}

# Get window count
cmd_windows() {
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        return count of windows
    end tell
end tell
"
}

# List UI elements
cmd_list() {
    echo -e "${YELLOW}Listing UI elements (this may take a moment)...${NC}"
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        set frontmost to true
        set elementList to \"\"
        try
            set windowRef to window 1
            repeat with uiElement in (entire contents of windowRef)
                try
                    set elementRole to (role of uiElement as string)
                    set elementDesc to (description of uiElement as string)
                    if elementDesc is not \"\" then
                        set elementList to elementList & elementRole & \": \" & elementDesc & linefeed
                    end if
                end try
            end repeat
        on error errMsg
            return \"Error: \" & errMsg
        end try
        return elementList
    end tell
end tell
"
}

# Press a key
cmd_key() {
    local key="$1"
    if [[ -z "$key" ]]; then
        echo -e "${RED}Error: key required${NC}"
        return 1
    fi
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        set frontmost to true
        keystroke \"$key\"
    end tell
end tell
"
}

# Press Cmd+key
cmd_cmd() {
    local key="$1"
    if [[ -z "$key" ]]; then
        echo -e "${RED}Error: key required${NC}"
        return 1
    fi
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        set frontmost to true
        keystroke \"$key\" using {command down}
    end tell
end tell
"
}

# Press key code
cmd_code() {
    local code="$1"
    if [[ -z "$code" ]]; then
        echo -e "${RED}Error: key code required${NC}"
        return 1
    fi
    run_script "
tell application \"System Events\"
    tell application process \"$APP_NAME\"
        set frontmost to true
        key code $code
    end tell
end tell
"
}

# Show key codes reference
show_keycodes() {
    echo ""
    echo "Common Key Codes:"
    echo "  36  = Enter/Return"
    echo "  49  = Space"
    echo "  51  = Delete/Backspace"
    echo "  53  = Escape"
    echo "  123 = Left Arrow"
    echo "  124 = Right Arrow"
    echo "  125 = Down Arrow"
    echo "  126 = Up Arrow"
    echo "  48  = Tab"
    echo ""
}

# Interactive mode
interactive() {
    echo ""
    echo "NoDraw UI Automation Helper"
    echo "================================"
    echo ""
    echo "Commands:"
    echo "  activate    - Bring app to front"
    echo "  windows     - Show window count"
    echo "  list        - List UI elements"
    echo "  key <k>     - Press key (e.g., 'key s')"
    echo "  cmd <k>     - Press Cmd+key (e.g., 'cmd k')"
    echo "  code <n>    - Press key code (e.g., 'code 53' for Escape)"
    echo "  codes       - Show key code reference"
    echo "  quit        - Exit"
    echo ""

    while true; do
        echo -n "> "
        read -r line
        local cmd=$(echo "$line" | awk '{print $1}')
        local arg=$(echo "$line" | awk '{print $2}')

        case "$cmd" in
            activate) cmd_activate ;;
            windows) cmd_windows ;;
            list) cmd_list ;;
            key) cmd_key "$arg" ;;
            cmd) cmd_cmd "$arg" ;;
            code) cmd_code "$arg" ;;
            codes) show_keycodes ;;
            quit|exit|q) break ;;
            "") ;;
            *) echo -e "${RED}Unknown command: $cmd${NC}" ;;
        esac
    done
}

# Main
case "$1" in
    activate) cmd_activate ;;
    windows) cmd_windows ;;
    list) cmd_list ;;
    key) cmd_key "$2" ;;
    cmd) cmd_cmd "$2" ;;
    code) cmd_code "$2" ;;
    codes) show_keycodes ;;
    "") interactive ;;
    *)
        echo "Unknown command: $1"
        echo "Use --help or run without arguments for interactive mode"
        exit 1
        ;;
esac
