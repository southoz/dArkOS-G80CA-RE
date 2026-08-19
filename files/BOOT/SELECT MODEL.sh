#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename -- "$script_dir")" == "dtb" ]]; then
    root_dir="$(dirname -- "$script_dir")"
else
    root_dir="$script_dir"
fi

ini_path=""
for candidate in "$root_dir/r36_devices.ini" "$root_dir/dtb/r36_devices.ini"; do
    if [[ -f "$candidate" ]]; then
        ini_path="$candidate"
        break
    fi
done

pause_if_interactive() {
    if [[ -t 0 ]]; then
        read -r -p "Press Enter to continue..." _
    fi
}

die() {
    printf 'ERROR: %s\n' "$1" >&2
    pause_if_interactive
    exit 1
}

[[ -n "$ini_path" ]] || die "r36_devices.ini not found"

declare -A device_variant=()
declare -A grouped_devices=()
declare -a devices=()
current_section=""

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "${line:0:1}" == ";" || "${line:0:1}" == "#" ]] && continue

    if [[ "$line" =~ ^\[(.*)\]$ ]]; then
        current_section="${BASH_REMATCH[1]}"
        current_section="${current_section#"${current_section%%[![:space:]]*}"}"
        current_section="${current_section%"${current_section##*[![:space:]]}"}"
        devices+=("$current_section")
        continue
    fi

    if [[ -n "$current_section" && "$line" =~ ^([^=]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ "$key" == "variant" ]]; then
            device_variant["$current_section"]="$value"
        fi
    fi
done < "$ini_path"

(( ${#devices[@]} > 0 )) || die "No devices found in INI"

for device in "${devices[@]}"; do
    variant="${device_variant[$device]:-unknown}"
    if [[ -n "${grouped_devices[$variant]:-}" ]]; then
        grouped_devices["$variant"]+=$'\n'"$device"
    else
        grouped_devices["$variant"]="$device"
    fi
done

printf '\n==================================================\n'
printf '   R36S DTB Firmware Selector\n'
printf '==================================================\n\n'
printf 'Root folder: %s\n' "$root_dir"
printf 'Using INI: %s\n' "$ini_path"
printf '\nReading devices...\n'
printf '\nAvailable devices:\n\n'

declare -a sorted_variants=()
for preferred in r36s clone soysauce; do
    if [[ -n "${grouped_devices[$preferred]:-}" ]]; then
        sorted_variants+=("$preferred")
    fi
done
for variant in "${!grouped_devices[@]}"; do
    case "$variant" in
        r36s|clone|soysauce) ;;
        *) sorted_variants+=("$variant") ;;
    esac
done

declare -A device_by_number=()
global_index=1

for variant in "${sorted_variants[@]}"; do
    mapfile -t devices_in_group <<< "${grouped_devices[$variant]}"
    (( ${#devices_in_group[@]} > 0 )) || continue

    printf 'Variant: %s\n' "$variant"
    printf '%*s\n' 70 '' | tr ' ' '-'

    half=$(( (${#devices_in_group[@]} + 1) / 2 ))
    for ((row = 0; row < half; row++)); do
        left_part=""
        right_part=""

        if (( row < ${#devices_in_group[@]} )); then
            num=$global_index
            left_part="$(printf '%4d. %s' "$num" "${devices_in_group[$row]}")"
            device_by_number["$num"]="${devices_in_group[$row]}"
            ((global_index++))
        fi

        right_index=$(( row + half ))
        if (( right_index < ${#devices_in_group[@]} )); then
            num=$global_index
            right_part="$(printf '%4d. %s' "$num" "${devices_in_group[$right_index]}")"
            device_by_number["$num"]="${devices_in_group[$right_index]}"
            ((global_index++))
        fi

        printf '%-40s%s\n' "$left_part" "$right_part"
    done

    printf '\n'
done

printf '%*s\n' 70 '' | tr ' ' '='
printf 'Total: %d devices\n' "${#devices[@]}"

printf '\nSelect number (1-%d)\n' "${#devices[@]}"
read -r raw_selection
selection="${raw_selection#"${raw_selection%%[![:space:]]*}"}"
selection="${selection%"${selection##*[![:space:]]}"}"

if [[ -z "$selection" || ! "$selection" =~ ^[0-9]+$ ]]; then
    printf 'Please enter a valid number.\n' >&2
    pause_if_interactive
    exit 1
fi

if (( selection < 1 || selection > ${#devices[@]} )); then
    printf 'Number must be between 1 and %d\n' "${#devices[@]}" >&2
    pause_if_interactive
    exit 1
fi

chosen="${device_by_number[$selection]}"
variant="${device_variant[$chosen]:-}"
[[ -n "$variant" ]] || die "No 'variant' defined for $chosen"

printf '\nSelected : %s\n' "$chosen"
printf 'Variant  : %s\n' "$variant"

source_folder="$root_dir/dtb/$variant/$chosen"
[[ -d "$source_folder" ]] || die "Folder not found: $source_folder"

printf '\nWill copy files from:\n'
printf '  %s\n' "$source_folder"

printf '\nFiles that will be copied from source folder:\n'
shopt -s nullglob dotglob
files_to_copy=("$source_folder"/*)
if (( ${#files_to_copy[@]} == 0 )); then
    printf '  WARNING: No files found in source folder!\n'
else
    for file in "${files_to_copy[@]}"; do
        [[ -f "$file" ]] || continue
        printf '  %s\n' "$(basename -- "$file")"
    done
fi

printf '\n.dtb files in root that will be deleted/overwritten:\n'
existing_dtbs=("$root_dir"/*.dtb)
if (( ${#existing_dtbs[@]} == 0 )); then
    printf '  (none currently present)\n'
else
    for file in "${existing_dtbs[@]}"; do
        printf '  %s\n' "$(basename -- "$file")"
    done
fi

printf '\n'
read -r -p "Proceed with copy? (Y/N) " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    printf 'Cancelled.\n'
    pause_if_interactive
    exit 0
fi

printf '\nDeleting old .dtb files in root...\n'
if (( ${#existing_dtbs[@]} > 0 )); then
    rm -f -- "${existing_dtbs[@]}"
    printf 'Deleted:\n'
    for file in "${existing_dtbs[@]}"; do
        printf '  %s\n' "$(basename -- "$file")"
    done
else
    printf '  No .dtb files to delete\n'
fi

printf '\nCopying new files to root...\n'
copied_count=0
for file in "${files_to_copy[@]}"; do
    [[ -f "$file" ]] || continue
    cp -f -- "$file" "$root_dir/"
    ((++copied_count))
done

if (( copied_count > 0 )); then
    printf 'Copied:\n'
    for file in "${files_to_copy[@]}"; do
        [[ -f "$file" ]] || continue
        printf '  %s\n' "$(basename -- "$file")"
    done
else
    printf '  No files were copied (source may be empty)\n'
fi

printf '\n==================================================\n'
printf '   SUCCESS - DTB files updated for:\n'
printf '   %s\n' "$chosen"
printf '   Variant: %s\n' "$variant"
printf '==================================================\n\n'

pause_if_interactive
