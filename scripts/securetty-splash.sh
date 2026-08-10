#!/bin/bash
# securetty-splash.sh — unified fastfetch-style splash renderer
# Usage: source this file and call show_splash with info lines as arguments
#   show_splash "Label1|Value1" "Label2|Value2" "---|" "Label3|Value3"
# Use "---|" for separator lines. Max ~12 info lines fit alongside the art.
# Use "--tagline|text" to override the tagline below the art.
# Call show_splash with no args for art + default tagline only (help mode).

_SPLASH_ART=(
    '  ______                            _______ _______ _     _'
    ' / _____)                          (_______|_______) |   | |'
    '( (____  _____  ____ _   _  ____ _____ _       _   | |___| |'
    ' \____ \| ___ |/ ___) | | |/ ___) ___ | |     | |  |_____  |'
    ' _____) ) ____( (___| |_| | |   | ____| |     | |   _____| |'
    '(______/|_____)\____)____/|_|   |_____)_|     |_|  (_______|'
)
_SPLASH_ART_WIDTH=63
_SPLASH_TAGLINE="Sandboxed AI development environment"

show_splash() {
    local C='\033[0;36m'
    local W='\033[1;37m'
    local D='\033[2m'
    local N='\033[0m'
    local SEP_CHAR='─'

    local tagline="$_SPLASH_TAGLINE"
    local -a info_lines=()

    for arg in "$@"; do
        if [[ "$arg" == "--tagline|"* ]]; then
            tagline="${arg#--tagline|}"
        else
            info_lines+=("$arg")
        fi
    done

    local info_count=${#info_lines[@]}
    local art_count=${#_SPLASH_ART[@]}
    local total_lines=$((art_count + 2))
    [ "$info_count" -gt "$total_lines" ] && total_lines="$info_count"

    local gap="    "
    local sep_line=""
    for _ in $(seq 1 29); do sep_line="${sep_line}${SEP_CHAR}"; done

    echo ""
    local i
    for ((i = 0; i < total_lines; i++)); do
        local left="" right=""

        if [ "$i" -lt "$art_count" ]; then
            left="${C}${_SPLASH_ART[$i]}${N}"
            local pad=$(((_SPLASH_ART_WIDTH - ${#_SPLASH_ART[$i]})))
            [ "$pad" -gt 0 ] && left="${left}$(printf '%*s' "$pad" '')"
        elif [ "$i" -eq "$((art_count))" ]; then
            left=""
        elif [ "$i" -eq "$((art_count + 1))" ]; then
            left="  ${D}${tagline}${N}"
            local pad=$((_SPLASH_ART_WIDTH - ${#tagline} - 2))
            [ "$pad" -gt 0 ] && left="${left}$(printf '%*s' "$pad" '')"
        else
            left="$(printf '%*s' "$_SPLASH_ART_WIDTH" '')"
        fi

        if [ "$i" -lt "$info_count" ]; then
            local entry="${info_lines[$i]}"
            if [[ "$entry" == "---|"* ]]; then
                right="${D}${sep_line}${N}"
            else
                local label="${entry%%|*}"
                local value="${entry#*|}"
                right="${C}$(printf '%-9s' "$label")${N} ${W}${value}${N}"
            fi
        fi

        if [ "$i" -lt "$art_count" ]; then
            if [ -n "$right" ]; then
                echo -e "${left}${gap}${right}"
            else
                echo -e "${left}"
            fi
        elif [ "$i" -eq "$art_count" ]; then
            if [ -n "$right" ]; then
                echo -e "$(printf '%*s' "$_SPLASH_ART_WIDTH" '')${gap}${right}"
            else
                echo ""
            fi
        else
            if [ -n "$right" ]; then
                echo -e "${left}${gap}${right}"
            elif [ -n "$left" ]; then
                echo -e "${left}"
            fi
        fi
    done
    echo ""
}
