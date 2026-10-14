#!/bin/sh

# This script is used to add marks to the qor cases
# Usage: add_mark.sh --case_dir <case_dir> --mark_dir <mark_dir> 

function usage() {
    echo "Usage: $0 --case_dir <case_dir> --mark_dir <mark_dir>"
    echo "Options:"
    echo "  -c, --case_dir   Directory containing the case files"
    echo "  -m, --mark_dir   Directory containing the mark files"
    echo "  -h, --help       Display this help message"
}

ARGS=$(getopt -o "c:m:h" --long "case_dir:,mark_dir:,help" -n "$0" -- "$@")
eval set -- "$ARGS"

while true; do
    case "$1" in
        -c|--case_dir)
            case_dir="$2"
            shift 2
            ;;
        -m|--mark_dir)
            mark_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${case_dir}" || -z "${mark_dir}" ]]; then
    echo "Error: Both --case_dir and --mark_dir must be specified."
    usage
    exit 1
fi

find "${case_dir}" -type f -name "*.tcl" | while read -r case_file; do
    qor_case_path="$(readlink -f "${case_file}")"
    qor_case_relate_path="${qor_case_path##*EnnocadProject/}"
    qor_case_name="$(basename "${qor_case_path}" .tcl)"

    if [[ -f "${mark_dir}/${qor_case_relate_path}-dir/${qor_case_name}.stdout" ]]; then
        mark_file="${mark_dir}/${qor_case_relate_path}-dir/${qor_case_name}.stdout"
        echo "Adding mark from ${mark_file} to ${qor_case_path}"
        # get thread mark content
        
        # get runtime/memory mark content
        # | Command      | Elapse Time (H:M:S)   | CPU Time (H:M:S)      | Peak Memory (MB) |
        # | Overall      | 13 mins : 54.561 secs | 14 mins : 13.190 secs | 19703.082        |
        OVERALL_LINE=$(grep '^|[[:space:]]*Overall[[:space:]]*|' ${mark_file})
        ET_STR=$(echo "$OVERALL_LINE" | awk -F'[|]' '{print $3}' | xargs)
        PMEM=$(echo "$OVERALL_LINE" | awk -F'[|]' '{print $5}' | xargs)

        # h=0;m=0;s=0
        # if [[ $ET_STR =~ ([0-9.]+)\ hours ]]; then h=${BASH_REMATCH[1]}; fi
        # if [[ $ET_STR =~ ([0-9.]+)\ mins ]]; then m=${BASH_REMATCH[1]}; fi
        # if [[ $ET_STR =~ ([0-9.]+)\ secs ]]; then s=${BASH_REMATCH[1]}; fi

        # ETime=$(echo "$h * 3600 + $m * 60 + $s" | bc -l | sed 's/^\./0./')
        ETime="${ET_STR}"
    else
        echo -e "\e[31mNo mark file found for ${qor_case_name}, skipping.\e[0m"
    fi
    
    if [[ "${qor_case_path}" =~ .*_([0-9]+)threads.tcl ]]; then
        thread="${BASH_REMATCH[1]}"
        # echo "命中，thread = $thread"
    elif [[ "${qor_case_path}" =~ .*_master(_[0-9]+)?\.tcl || "${qor_case_path}" =~ .*-master(-[0-9]+)?\.tcl ]]; then
        qor_case_dir="$(dirname "${qor_case_path}")"
        max_thread=1
        cases=$(find "${qor_case_dir}" -maxdepth 1 -type f -name "*threads.tcl")
        for case in ${cases}; do
            if [[ "${case}" =~ .*_([0-9]+)threads\.tcl ]]; then
                thread_num="${BASH_REMATCH[1]}"
                if (( ${thread_num} > ${max_thread} )); then
                    max_thread=${thread_num}
                fi
            fi
        done
        thread="${max_thread}"
        # echo "命中 master，thread = $thread"
    else
        # echo "未命中 _XXthreads 格式"
        thread=1
    fi

    if [[ "${qor_case_path}" =~ .*/EnnocadProject/reg/([^/\ ]+)/.* ]]; then
        product_name="${BASH_REMATCH[1]}"
    else
        echo "${qor_case_path}: 未命中 EnnocadProject 格式"
        product_name="unknown"
    fi

    echo "Extracted values for ${qor_case_name}: thread=${thread}, ETime=${ETime}, PMEM=${PMEM}, product_name=${product_name}"

    readarray -t lines < "${case_file}"

    declare -A target_val
    declare -A found_flag
    declare -A old_val
    declare -A line_num

    target_val["multi_thread"]="${thread}"
    target_val["runtime"]="{${ETime}}"
    target_val["memory"]="{${PMEM} MB}"
    target_val["product_name"]="${product_name}"

    for key in "${!target_val[@]}"; do
        found_flag["$key"]=0
    done

    label_lineno=-1
    in_label=0

    for idx in "${!lines[@]}"; do
        line="${lines[$idx]}"
        sed_line=$((idx + 1))

        if [[ "${line}" =~ ^[[:space:]]*label[[:space:]]+test_case_status[[:space:]]*:[[:space:]]*$ ]]; then
            label_lineno=${sed_line}
            in_label=1
            continue
        fi

        if [[ ${in_label} -eq 1 ]]; then
            if [[ "${line}" =~ ^[[:space:]]*set[[:space:]]+([a-zA-Z0-9_-]+)[[:space:]]+(.*)[[:space:]]*$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                if [[ -n "${target_val[$key]}" ]]; then
                    old_val["$key"]="${value}"
                    found_flag["$key"]=1
                    line_num["$key"]=${sed_line}
                fi
            fi
        fi
    done

    for k in "${!target_val[@]}"; do
        if [[ ${found_flag[$k]} -eq 1 ]]; then
            if (( "${old_val[$k]}" < "${target_val[$k]}" )); then
                ln="${line_num[$k]}"
                sed -i "${ln}s/^[[:space:]]*set[[:space:]]\+${k}[[:space:]]\+.*$/set ${k} ${target_val[$k]}/" "${case_file}"
                echo "Updated ${k} from ${old_val[$k]} to ${target_val[$k]} in ${case_file}"
            fi
        fi
    done

    insert_list=()
    for k in "${!target_val[@]}"; do
        if [[ ${found_flag[$k]} -eq 0 ]]; then
            insert_list+=("set ${k} ${target_val[$k]}")
        fi
    done

    if [[ ${label_lineno} -ne -1 && ${#insert_list[@]} -gt 0 ]]; then
        for (( i=${#insert_list[@]}-1; i>=0; i-- )); do
            sed -i "${label_lineno}a${insert_list[$i]}" "${case_file}"
            echo "Inserted ${insert_list[$i]} after line ${label_lineno} in ${case_file}"
        done
    fi

    unset target_val found_flag old_val line_num
done

