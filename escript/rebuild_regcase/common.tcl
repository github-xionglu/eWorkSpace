#!/usr/local/bin/tclsh8.6

namespace eval __GENERIC_PROCS__ {

    proc __optParse__ {defArgDict defKeyDict defKeyValDict usageProc argv} {
        # 解析命令行参数
        # 输入：自定义参数及其缺省值字典，自定义bool选项及其缺省值字典，自定义选项-参数值缺省值字典，usage proc
        # 返回：自定义参数、选项变量

        # 初始化参数字典
        set dArg [dict merge ${defArgDict} ${defKeyDict} ${defKeyValDict}]

        set argList [dict keys ${defArgDict}]
        set keyList [dict keys ${defKeyDict}]
        set keyValList [dict keys ${defKeyValDict}]

        set maxArgLen [llength ${argList}]
        set nArgParsed 0

        # 判断是否提供了usage proc
        set printUsageProc [expr {[info exists usageProc] && [uplevel 1 info procs ${usageProc}] ne ""}]

        # 解析命令行参数
        set i 0
        set argFlag false
        while {${i} < [llength ${argv}]} {
            set arg [lindex ${argv} ${i}]

            if { ! ${argFlag} } {
                if {[string match "--" ${arg}]} {
                    set argFlag true
                } elseif {[string match "-*" ${arg}]} {
                    if { [dict exists ${defKeyDict} ${arg}] && ! [dict exists ${defKeyValDict} ${arg}] } {
                        dict set dArg ${arg} [expr { ! [dict get ${defKeyDict} ${arg}]}]
                    } elseif { [dict exists ${defKeyValDict} ${arg}] } {
                        if { ${i} + 1 < [llength ${argv}] } {
                            set val [lindex ${argv} [expr {${i} + 1}]]
                            # Greedy consumption: if the next token after the value
                            # does not look like an option (doesn't start with "-"),
                            # keep appending it to form a proper list value.
                            # This allows shell-split arguments like:
                            #   -cmd old_cmd new_cmd   (instead of -cmd {old_cmd new_cmd})
                            set j [expr {${i} + 2}]
                            while { ${j} < [llength ${argv}] } {
                                set next [lindex ${argv} ${j}]
                                if {[string match "-*" ${next}]} { break }
                                lappend val ${next}
                                incr j
                            }
                            dict set dArg ${arg} ${val}
                            set i [expr {${j} - 1}]
                        } else {
                            puts "错误: 选项 ${arg} 缺少参数值"
                            if { ${printUsageProc} } { uplevel 1 ${usageProc} }
                            return -code error "选项 ${arg} 缺少参数值"
                        }
                    } else {
                        puts "错误: 未知的选项 — ${arg}"
                        if { ${printUsageProc} } { uplevel 1 ${usageProc} }
                        return -code error "未知的选项 — ${arg}"
                    }
                } else {
                    if { ${nArgParsed} < ${maxArgLen} } {
                        dict set dArg [lindex ${argList} ${nArgParsed}] ${arg}
                        incr nArgParsed
                    } else {
                        puts "错误: 多余的参数 — ${arg}"
                        if { ${printUsageProc} } { uplevel 1 ${usageProc} }
                        return -code error "多余的参数 — ${arg}"
                    }
                }
            } else {
                if { ${nArgParsed} < ${maxArgLen} } {
                    dict set dArg [lindex ${argList} ${nArgParsed}] ${arg}
                    incr nArgParsed
                } else {
                    puts "错误: 多余的参数 — ${arg}"
                    if { ${printUsageProc} } { uplevel 1 ${usageProc} }
                    return -code error "多余的参数 — ${arg}"
                }
            }
            incr i
        }
        dict for {key val} ${dArg} {
            upvar 1 ${key} var
            set var ${val}
        }
    }

    proc __print_date__ {} {
        return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    }

    proc __strip_absolute_path__ {str} {
        # 将字符串中的文件绝对路径转化为文件名
        set _output_str_ ${str}

        set _pattern_ {[^a-zA-Z0-9_\-\./\[\]](/(?:[a-zA-Z0-9_\-\./]+)*[a-zA-Z0-9_\-\.]+)}
        set _all_paths_ [regexp -all -inline ${_pattern_} ${str}]

        set _uniq_paths_ {}
        foreach _path_ ${_all_paths_} {
            if { ${_path_} ni ${_uniq_paths_} } {
                lappend _uniq_paths_ ${_path_}
            }
        }
        set _uniq_paths_ [lsort -decreasing -dictionary ${_uniq_paths_}]
        foreach _uniq_path_ ${_uniq_paths_} {
            set _tail_name_ [file tail ${_uniq_path_}]
            set _output_str_ [string map [list ${_uniq_path_} ${_tail_name_}] ${_output_str_}]
        }
        return ${_output_str_}
    }

    proc __report_message_usage__ {} {
        puts {Usage: __report_message__ <message> [-help] [-debug] [-severity <severity>]}
        puts {Options:}
        puts {  <message>               The message to be reported.}
        puts {  -help                   Print this usage message.}
        puts {  -debug                  Enable debug mode.}
        puts {  -severity <severity>    The severity of the message (, warn, error).}
        puts {  -color <color>          The color of the message (red, green, blue, yellow, magenta, cyan).}
        puts {}
        puts {Example:}
        puts {  __report_message__ "This is an info message" -severity info}
        puts {  __report_message__ "This is a warning message" -severity warn}
        puts {}
    }
    proc __report_message__ {args} {
        set defArgDict [dict create msg ""]
        set defKeyDict [dict create -help false -debug false]
        set defKeyValDict [dict create -severity "info" -color ""]

        # 解决「消息首字母为 - 被误判为选项」的问题：
        # __optParse__ 会把任何以 - 开头的 token 当成选项名查询 defKeyDict/defKeyValDict。
        # 这里先按「已知选项 + 其值」与「其余 token」做分离，再把其余 token 拼成单条消息，
        # 并在前面注入 -- 保护，保证消息即便以 - 开头也不会被解析成选项。
        set _args_ ${args}
        set _hasSep_ false
        foreach _a_ ${_args_} {
            if { ${_a_} eq "--" } { set _hasSep_ true; break }
        }
        if { ! ${_hasSep_} } {
            set _opts_ {}
            set _msgTokens_ {}
            set _i_ 0
            set _n_ [llength ${_args_}]
            while { ${_i_} < ${_n_} } {
                set _a_ [lindex ${_args_} ${_i_}]
                if { ${_a_} in {-help -debug} } {
                    lappend _opts_ ${_a_}
                    incr _i_
                } elseif { ${_a_} in {-severity -color} } {
                    lappend _opts_ ${_a_}
                    incr _i_
                    if { ${_i_} < ${_n_} } { lappend _opts_ [lindex ${_args_} ${_i_}]; incr _i_ }
                } else {
                    # 其余所有 token（含以 - 开头的消息）一律视作消息
                    lappend _msgTokens_ {*}[lrange ${_args_} ${_i_} end]
                    break
                }
            }
            if { [llength ${_msgTokens_}] > 0 } {
                set _msg_ [join ${_msgTokens_} " "]
                set _args_ [concat ${_opts_} [list -- ${_msg_}]]
            }
        }
        __optParse__ ${defArgDict} ${defKeyDict} ${defKeyValDict} __report_message_usage__ ${_args_}

        if { ${-help} } { __report_message_usage__ ; return }

        set severityList [list info warn error]
        if { ${-severity} ni ${severityList} } { error "Invalid value, ${-severity}, of \"-severity\", valid value: [join ${severityList} {, }]" }

        set defaultColorCode "\033\[0m"
        switch -nocase -exact -- ${-color} {
            red {set colorCode "\033\[31m"}
            green {set colorCode "\033\[32m"}
            blue {set colorCode "\033\[34m"}
            yellow {set colorCode "\033\[33m"}
            magenta {set colorCode "\033\[35m"}
            cyan {set colorCode "\033\[36m"}
            default {
                puts "warn: Invalid value, ${-color}, of \"-color\", valid value: [join {red green blue yellow magenta cyan} {, }], default value: \\033\\\[0m"
                set colorCode "\033\[0m"
            }
        }

        set debugMode [expr {[info exists ::isDebug] && ${::isDebug} == 1}]
        if { ! ${-debug} } {
            puts "${colorCode}[format "%s: %s" ${-severity} ${msg}]${defaultColorCode}"
        } else {
            if { ${debugMode} } {
                puts "${colorCode}[format "DEBUG_%s: %s" ${-severity} ${msg}]${defaultColorCode}"
            } else {
                ; # do nothing
            }
        }
    }

    proc __backup_file__ {file_path} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."
        if { [file exists ${file_path}] } {
            set _file_name_ [file rootname [file tail ${file_path}]]
            set _file_exp_ [string trimleft [file tail ${file_path}] ${_file_name_}]

            set i 1
            while {true} {
                set num [format "%03d" ${i}]
                set _backup_file_ [format "%s-%s%s" ${_file_name_} ${num} ${_file_exp_}]
                if { [file exists ${_backup_file_}] } {
                    incr i
                } else {
                    break
                }
            }
            file rename ${file_path} ${_backup_file_}
            __report_message__ "[__print_date__]: The result file is exists, it is renamed to ${_backup_file_} successfully." -debug
        }
        __report_message__ "[__print_date__]: End to [lindex [info level 0] 0]."
    }

    proc __list_differences__ {list1 list2} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."
        set diff1 [list]
        set diff2 [list]

        foreach item [concat ${list1} ${list2}] {
            set in_list1 [expr {[lsearch -exact ${list1} ${item}] != -1}]
            set in_list2 [expr {[lsearch -exact ${list2} ${item}] != -1}]
            if { ${in_list1} && ${in_list2} } {
                continue
            } elseif { ! ${in_list1} } {
                lappend diff2 ${item}
            } elseif { ! ${in_list2} } {
                lappend diff1 ${item}
            } else {
                __report_message__ "Invalid flag result, please check" -severity warn
            }
        }
        __report_message__ "[__print_date__] End to [lindex [info level 0] 0]"
        return [dict create diff1 ${diff1} diff2 ${diff2}]
    }

    proc __csv_escape_value__ {val} {
        set escaped_val [string map {\" \"\"} ${val}]
        if { [regexp {[,\"\n]} ${escaped_val}] } {
            return "\"${escaped_val}\""
        } else {
            return ${escaped_val}
        }
    }

    proc __extract_partial_text_rows_columns__ {str {rows {}} {cols {}} {splitMark { }} } {
        set allrows [expr {${rows} == {} || [lsearch ${rows} 0] >= 0}]
        set allcols [expr {${cols} == {} || [lsearch ${cols} 0] >= 0}]

        if { ${allrows} } {
            if { ${allcols} } {
                return ${str}
            } else {
                set line_list [split ${str} "\n"]
                set new_line_list {}
                foreach line ${line_list} {
                    set col_list [split ${line} ${splitMark}]
                    set col_num [llength ${col_list}]
                    set new_line_temp {}
                    foreach col ${cols} {
                        if { [expr abs(${col}) > ${col_num} ] } {
                            lappend new_line_temp {}
                        } elseif { ${col} > 0 } {
                            lappend new_line_temp [lindex ${col_list} [expr {${col} - 1}]]
                        } else {
                            lappend new_line_temp [lindex ${col_list} end-[expr {abs(${col}) - 1}]]
                        }
                    }
                    lappend new_line_list [join ${new_line_temp} ${splitMark}]
                }
                return [join ${new_line_list} "\n"]
            }
        } else {
            set line_list [split ${str} "\n"]
            set line_num [llength ${line_list}]
            set new_line_list {}
            foreach row ${rows} {
                if { [expr abs(${row}) > ${line_num}] } {
                    lappend new_line_list {}
                } elseif { ${row} > 0 } {
                    set line [lindex ${line_list} [expr {${row} - 1}]]
                    if { ${allcols} } {
                        lappend new_line_list ${line}
                    } else {
                        set col_list [split ${line} ${splitMark}]
                        set col_num [llength ${col_list}]
                        set new_line_temp {}
                        foreach col ${cols} {
                            if { [expr abs(${col}) > ${col_num} ] } {
                                lappend new_line_temp {}
                            } elseif { ${col} > 0 } {
                                puts "{${col} == [lindex ${col_list} [expr {${col} - 1}]]}"
                                lappend new_line_temp [lindex ${col_list} [expr {${col} - 1}]]
                            } else {
                                lappend new_line_temp [lindex ${col_list} end-[expr {abs(${col}) - 1}]]
                            }
                        }
                        lappend new_line_list [join ${new_line_temp} ${splitMark}]
                    }
                } else {
                    set line [lindex ${line_list} end-[expr {abs(${row}) - 1}]]
                    if { ${allcols} } {
                        lappend new_line_list ${line}
                    } else {
                        set col_list [split ${line} ${splitMark}]
                        set col_num [llength ${col_list}]
                        set new_line_temp {}
                        foreach col ${cols} {
                            if { [expr abs(${col}) > ${col_num} ] } {
                                lappend new_line_temp {}
                            } elseif { ${col} > 0 } {
                                lappend new_line_temp [lindex ${col_list} [expr {${col} - 1}]]
                            } else {
                                lappend new_line_temp [lindex ${col_list} end-[expr {abs(${col}) - 1}]]
                            }
                        }
                        lappend new_line_list [join ${new_line_temp} ${splitMark}]
                    }
                }
            }
            return [join ${new_line_list} "\n"]
        }
    }

    proc __extract_partial_result_str__ {str cmdDict} {
        if { ![dict exists ${cmdDict} "rows"] && ![dict exists ${cmdDict} "cols"] } {
            return ${str}
        } else {
            set rows {}
            set cols {}
            set split_mark { }
            if { [dict exists ${cmdDict} "rows"] } {
                set rows [dict get ${cmdDict} "rows"]
            }
            if { [dict exists ${cmdDict} "cols"] } {
                set cols [dict get ${cmdDict} "cols"]
            }
            if { [dict exists ${cmdDict} "split_symbol"] } {
                set split_mark [dict get ${cmdDict} "split_symbol"]
            }
            return [__extract_partial_text_rows_columns__ ${str} ${rows} ${cols} ${split_mark}]
        }
    }
}