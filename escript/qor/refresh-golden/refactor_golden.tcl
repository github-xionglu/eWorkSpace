#!/usr/bin/env tclsh
# refactor_golden.tcl
# 批量重构 golden 文件中的性能数据格式为 value(threshold) 风格。
# 用法: tclsh refactor_golden.tcl <path>

package require Tcl 8.5

proc usage {} {
    puts stderr "Usage: [file tail $::argv0] <path>"
    exit 1
}

if {$argc != 1} {
    usage
}

set root [file normalize [lindex $argv 0]]

if {![file isdirectory $root]} {
    puts stderr "Error: '$root' is not a directory"
    exit 1
}

# 递归查找指定目录下的所有 .tcl 文件
proc find_tcl_files {dir} {
    set result {}
    foreach item [glob -nocomplain -directory $dir -type d *] {
        set tail [file tail $item]
        if {$tail eq "." || $tail eq ".."} {
            continue
        }
        lappend result {*}[find_tcl_files $item]
    }
    foreach f [glob -nocomplain -directory $dir -type f *.tcl] {
        lappend result $f
    }
    return $result
}

# 从 .tcl 文件中提取 __QOR_GEN_AND_COMP__::__cmp_qor_data__ 的第一个参数
proc get_public_threshold {tcl_file} {
    set fh [open $tcl_file r]
    set content [read $fh]
    close $fh

    set L [format %c 123]
    set R [format %c 125]

    # 先定位命令关键字，兼容 __QOR_GEN_AND_COMP__::__cmp_qor_data__ 与带空格写法
    set cmd_re {__QOR_GEN_AND_COMP__\s*::__cmp_qor_data__}
    if {![regexp $cmd_re $content match]} {
        return ""
    }

    set pos   [string first $match $content]
    set start [expr {$pos + [string length $match]}]
    set len   [string length $content]

    # 跳过命令后的空白
    while {$start < $len && [string is space [string index $content $start]]} {
        incr start
    }

    if {$start >= $len} {
        return ""
    }

    set first [string index $content $start]

    if {$first eq "\""} {
        # 双引号参数
        set end [expr {$start + 1}]
        while {$end < $len} {
            set c [string index $content $end]
            if {$c eq "\\"} {
                incr end 2
            } elseif {$c eq "\""} {
                break
            } else {
                incr end
            }
        }
        return [string range $content [expr {$start + 1}] [expr {$end - 1}]]
    } elseif {$first eq $L} {
        # 花括号参数：匹配嵌套
        set depth 1
        set end [expr {$start + 1}]
        while {$end < $len && $depth > 0} {
            set c [string index $content $end]
            if {$c eq "\\"} {
                incr end 2
            } elseif {$c eq $L} {
                incr depth
                incr end
            } elseif {$c eq $R} {
                incr depth -1
                if {$depth == 0} {
                    break
                }
                incr end
            } else {
                incr end
            }
        }
        return [string range $content [expr {$start + 1}] [expr {$end - 1}]]
    } else {
        # 普通参数：到下一个空白
        set end $start
        while {$end < $len && ![string is space [string index $content $end]]} {
            incr end
        }
        set arg [string range $content $start [expr {$end - 1}]]
    }

    set arg [string trim $arg]

    # 防御：命令替换的右括号紧邻参数时会被误收入（如 {15%}] 中的 ]）
    if {[string index $arg end] eq "]"} {
        set arg [string range $arg 0 end-1]
    }

    return $arg
}

# 将单个 golden 值统一为 value(threshold) 风格
proc format_value {value public_threshold} {
    set value [string trim $value]

    # 已经是 value(threshold) 风格则保留
    if {[regexp {\([^)]+\)$} $value]} {
        return $value
    }

    # 移除千分位逗号，并在末尾追加公共阈值
    set num [string map {, ""} $value]
    return "${num}($public_threshold)"
}

# 读取并重构单个 golden 文件
# 将整个文件内容作为 Tcl dict 解析（支持单行或多行），并统一输出为每行一个顶层 key 的多行格式。
proc refactor_golden_file {golden_file public_threshold} {
    if {![file exists $golden_file]} {
        return
    }

    set fh [open $golden_file r]
    set raw [read $fh]
    close $fh

    # 过滤空行与注释行，把有效内容拼成一个可解析的 dict 列表
    set effective ""
    foreach line [split $raw \n] {
        set trimmed [string trim $line]
        if {$trimmed eq "" || [string match "#*" $trimmed]} {
            continue
        }
        append effective " " $trimmed
    }
    set effective [string trim $effective]

    if {$effective eq ""} {
        return
    }

    # 用 Tcl dict 解析嵌套结构
    if {[catch {set d [dict create {*}$effective]} err]} {
        puts stderr "Warning: failed to parse dict in $golden_file: $err"
        return
    }

    set out_lines {}
    dict for {top_key inner_dict} $d {
        set inner_str ""
        dict for {k v} $inner_dict {
            append inner_str "$k [format_value $v $public_threshold] "
        }
        set inner_str [string trimright $inner_str]
        lappend out_lines "$top_key {$inner_str}"
    }

    set fh [open $golden_file w]
    puts $fh [join $out_lines \n]
    close $fh
}

set tcl_files [find_tcl_files $root]

foreach tcl_file $tcl_files {
    set threshold [get_public_threshold $tcl_file]
    if {$threshold eq ""} {
        puts "Skip $tcl_file: no public threshold found"
        continue
    }

    set base      [file rootname $tcl_file]
    set golden    "${base}.golden"
    set arm_golden "${base}_arm.golden"

    puts "Processing $tcl_file (threshold=$threshold)"

    refactor_golden_file $golden $threshold
    refactor_golden_file $arm_golden $threshold
}

puts "Done"
