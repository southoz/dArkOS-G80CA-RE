RED='\033[0;31m'
MAGENTA='\033[0;35m'
DGRAY='\033[1;30m'
WHITE='\033[1;37m'
NC='\033[0m'
 
echo ""
echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}   R36S DTB Firmware Selector${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
 
# ── Determine root folder ────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 
if [[ "$(basename "$SCRIPT_DIR")" == "dtb" ]]; then
    ROOT_DIR="$(dirname "$SCRIPT_DIR")"
else
    ROOT_DIR="$SCRIPT_DIR"
fi
 
echo -e "${DCYAN}Root folder: $ROOT_DIR${NC}"
 
# ── Find INI ─────────────────────────────────
INI_PATH=""
for candidate in "$ROOT_DIR/r36_devices.ini" "$ROOT_DIR/dtb/r36_devices.ini"; do
    if [[ -f "$candidate" ]]; then
        INI_PATH="$candidate"
        echo -e "${GREEN}Using INI: $INI_PATH${NC}"
        break
    fi
done
 
if [[ -z "$INI_PATH" ]]; then
    echo -e "${RED}ERROR: r36_devices.ini not found${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
# ── Parse INI ────────────────────────────────
echo ""
echo -e "${YELLOW}Reading devices...${NC}"
 
declare -A section_keys
declare -A section_values
declare -a section_order
 
current_section=""
 
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
 
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        current_section="${current_section#"${current_section%%[![:space:]]*}"}"
        current_section="${current_section%"${current_section##*[![:space:]]}"}"
        section_order+=("$current_section")
        section_keys["$current_section"]=""
 
    elif [[ -n "$current_section" && "$line" =~ ^([^=]+)=(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
 
        section_values["${current_section}__${key}"]="$value"
        if [[ -z "${section_keys[$current_section]}" ]]; then
            section_keys["$current_section"]="$key"
        else
            section_keys["$current_section"]+="${IFS:0:1}${key}"
        fi
    fi
done < "$INI_PATH"
 
total_sections="${#section_order[@]}"
 
if [[ "$total_sections" -eq 0 ]]; then
    echo -e "${RED}ERROR: No devices found in INI${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
# ── Group by variant ─────────────────────────
declare -A grouped_devices
declare -a all_variants_seen
 
for dev in "${section_order[@]}"; do
    v="${section_values["${dev}__variant"]:-unknown}"
    if [[ -v grouped_devices["$v"] ]]; then
        grouped_devices["$v"]+=$'\n'"$dev"
    else
        grouped_devices["$v"]="$dev"
        all_variants_seen+=("$v")
    fi
done

variant_display_order=("r36s" "clone" "soysauce")
declare -a sorted_variants
 
for v in "${variant_display_order[@]}"; do
    if [[ -v grouped_devices["$v"] ]]; then
        sorted_variants+=("$v")
    fi
done
 
for v in "${all_variants_seen[@]}"; do
    found=0
    for known in "${variant_display_order[@]}"; do
        [[ "$v" == "$known" ]] && found=1 && break
    done
    [[ "$found" -eq 0 ]] && sorted_variants+=("$v")
done
 
# ── Two-column menu ───────────────────────────
echo ""
echo -e "${CYAN}Available devices:${NC}"
echo ""
 
global_index=1
declare -a device_list_keys
declare -a device_list_names
 
for variant in "${sorted_variants[@]}"; do
    IFS=$'\n' read -r -d '' -a devs_in_group <<< "${grouped_devices[$variant]}"$'\0' || true
 
    count="${#devs_in_group[@]}"
    [[ "$count" -eq 0 ]] && continue
 
    echo -e "${MAGENTA}Variant: $variant${NC}"
    echo -e "${DGRAY}$(printf '%0.s-' {1..70})${NC}"
 
    half=$(( (count + 1) / 2 ))
 
    for (( row=0; row<half; row++ )); do
        left_part=""
        right_part=""
 
        if (( row < half )); then
            num=$global_index
            left_part="$(printf '%4d. %s' "$num" "${devs_in_group[$row]}")"
            device_list_keys+=("$num")
            device_list_names+=("${devs_in_group[$row]}")
            (( global_index++ ))
        fi
 
        right_idx=$(( row + half ))
        if (( right_idx < count )); then
            num=$global_index
            right_part="$(printf '%4d. %s' "$num" "${devs_in_group[$right_idx]}")"
            device_list_keys+=("$num")
            device_list_names+=("${devs_in_group[$right_idx]}")
            (( global_index++ ))
        fi
 
        printf "%-40s%s\n" "$left_part" "$right_part"
    done
 
    echo ""
done
 
echo -e "${DGRAY}$(printf '%0.s=' {1..70})${NC}"
echo -e "${CYAN}Total: $total_sections devices${NC}"
 
# ── Selection ─────────────────────────────────
echo ""
echo -e "${CYAN}Select number (1-${total_sections})${NC}"
read -rp "> " raw_input
selection="${raw_input// /}"
 
if [[ -z "$selection" || ! "$selection" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Please enter a valid number.${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
sel_num=$(( 10#$selection ))
 
if (( sel_num < 1 || sel_num > total_sections )); then
    echo -e "${RED}Number must be between 1 and ${total_sections}${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
# Look up chosen device by index
chosen=""
for i in "${!device_list_keys[@]}"; do
    if [[ "${device_list_keys[$i]}" -eq "$sel_num" ]]; then
        chosen="${device_list_names[$i]}"
        break
    fi
done
 
if [[ -z "$chosen" ]]; then
    echo -e "${RED}ERROR: Could not resolve selection${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
variant="${section_values["${chosen}__variant"]:-}"
 
if [[ -z "$variant" ]]; then
    echo -e "${RED}ERROR: No 'variant' defined for $chosen${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
echo ""
echo -e "${GREEN}Selected : $chosen${NC}"
echo -e "${GREEN}Variant  : $variant${NC}"
 
# ── Build path ───────────────────────────────
source_folder="$ROOT_DIR/dtb/$variant/$chosen"
 
if [[ ! -d "$source_folder" ]]; then
    echo -e "${RED}ERROR: Folder not found: $source_folder${NC}"
    read -rp "Press Enter to exit..."
    exit 1
fi
 
echo ""
echo -e "${CYAN}Will copy files from:${NC}"
echo -e "${WHITE}  $source_folder${NC}"
 
# ── Preview files to copy ────────────────────
echo ""
echo "Files that will be copied from source folder:"
mapfile -t files_to_copy < <(find "$source_folder" -maxdepth 1 -type f 2>/dev/null)
 
if [[ "${#files_to_copy[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}  WARNING: No files found in source folder!${NC}"
else
    for f in "${files_to_copy[@]}"; do
        echo "  $(basename "$f")"
    done
fi
 
# ── Preview .dtb files in root ───────────────
echo ""
echo ".dtb files in root that will be deleted/overwritten:"
mapfile -t existing_dtbs < <(find "$ROOT_DIR" -maxdepth 1 -type f -name "*.dtb" 2>/dev/null)
 
if [[ "${#existing_dtbs[@]}" -eq 0 ]]; then
    echo "  (none currently present)"
else
    for f in "${existing_dtbs[@]}"; do
        echo "  $(basename "$f")"
    done
fi
 
echo ""
read -rp "Proceed with copy? (Y/N) " confirm
 
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    read -rp "Press Enter to exit..."
    exit 0
fi
 
# ── Delete old .dtb files ────────────────────
echo ""
echo -e "${YELLOW}Deleting old .dtb files in root...${NC}"
 
mapfile -t to_delete < <(find "$ROOT_DIR" -maxdepth 1 -type f -name "*.dtb" 2>/dev/null)
 
if [[ "${#to_delete[@]}" -gt 0 ]]; then
    echo "Deleted:"
    for f in "${to_delete[@]}"; do
        echo "  $(basename "$f")"
        rm -f "$f"
    done
else
    echo "  No .dtb files to delete"
fi
 
# ── Copy new files ───────────────────────────
echo ""
echo -e "${YELLOW}Copying new files to root...${NC}"
 
mapfile -t copied_files < <(find "$source_folder" -maxdepth 1 -type f 2>/dev/null)
 
if [[ "${#copied_files[@]}" -gt 0 ]]; then
    echo "Copied:"
    for f in "${copied_files[@]}"; do
        cp -f "$f" "$ROOT_DIR/"
        echo "  $(basename "$f")"
    done
else
    echo -e "${YELLOW}  No files were copied (source may be empty)${NC}"
fi
 
# -- Apply resolution-matched splash image --
# Mirrors the behaviour already present in select_device.ps1, which picks the
# logo from the device's `resolution` key. Built from the resolution string so
# new panel sizes need no code change.
resolution="${section_values["${chosen}__resolution"]:-}"
logo_dir="$ROOT_DIR/dtb/logo"

echo ""
echo -e "${YELLOW}Applying boot images for resolution: ${resolution:-unknown}${NC}"

if [[ -z "$resolution" ]]; then
    echo -e "${YELLOW}  No 'resolution' key for $chosen - leaving logo.bmp untouched${NC}"
elif [[ ! -d "$logo_dir" ]]; then
    echo -e "${YELLOW}  No dtb/logo folder found - skipping${NC}"
else
    src_logo="$logo_dir/logo-${resolution}.bmp"
    if [[ -f "$src_logo" ]]; then
        cp -f "$src_logo" "$ROOT_DIR/logo.bmp"
        echo "  logo.bmp <- $(basename "$src_logo")"
    else
        echo -e "${YELLOW}  No logo-${resolution}.bmp - leaving logo.bmp untouched${NC}"
    fi

    # Battery images are resolution-specific too, and neither selector script
    # installs them today. Archive names do not always match the resolution
    # exactly (720x720 panels ship battery-720x270.zip), so fall back to width.
    res_width="${resolution%%x*}"
    src_batt="$logo_dir/battery-${resolution}.zip"
    if [[ ! -f "$src_batt" ]]; then
        src_batt="$(find "$logo_dir" -maxdepth 1 -type f -name "battery-${res_width}x*.zip" 2>/dev/null | head -n 1)"
    fi

    if [[ -n "$src_batt" && -f "$src_batt" ]]; then
        if command -v unzip >/dev/null 2>&1; then
            rm -f "$ROOT_DIR"/battery_*.bmp
            unzip -o -q "$src_batt" -d "$ROOT_DIR/"
            echo "  battery_*.bmp <- $(basename "$src_batt")"
        else
            echo -e "${YELLOW}  unzip unavailable - extract $(basename "$src_batt") to root manually${NC}"
        fi
    else
        echo -e "${YELLOW}  No battery archive matching ${resolution} - skipping${NC}"
    fi
fi

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}   SUCCESS - DTB files updated for:${NC}"
echo -e "${WHITE}   $chosen${NC}"
echo -e "${WHITE}   Variant: $variant${NC}"
echo -e "${WHITE}   Resolution: ${resolution:-unknown}${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
 