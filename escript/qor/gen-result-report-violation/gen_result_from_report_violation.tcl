#!/usr/local/bin/tclsh8.6

source ./common.tcl

################################################################################
## define the generate result proc                                             #
################################################################################

namespace eval __GEN_RESULT_FLOW__ {
    variable single_line_messageIds [lrange [redirect {get_message_config -single_line_log_style}] 2 end]
    variable show_timestamp [lindex [redirect {get_message_config -show_timestamp}] 1]

    namespace path [list {*}[namespace path] ::__GENERIC_PROCS__]

    proc __reset_config_message_usage__ {} {
        puts "__reset_config_message__ — 重置日志消息统计工具配置"
        puts ""
        puts "用法: __reset_config_message__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -reset_opts_vals_dict <dict>  重置配置选项及其值的字典 (默认 {-single_line_log_style \${::__GEN_RESULT_FLOW__::single_line_messageIds} -show_timestamp \${::__GEN_RESULT_FLOW__::show_timestamp}})"
        puts "  -help               打印此用法说明"
        puts ""
        puts "返回值: 无"
        puts ""
        puts "示例:"
        puts "  __reset_config_message__ -reset_opts_vals_dict {-single_line_log_style \${::__GEN_RESULT_FLOW__::single_line_messageIds} -show_timestamp \${::__GEN_RESULT_FLOW__::show_timestamp}}"
        puts ""
    }
    proc __reset_config_message__ {args} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."

        set defValDict [dict create]
        set defKeyDict [dict create -help 0]
        set defKeyValDict [dict create -reset_opts_vals_dict {-single_line_log_style ${::__GEN_RESULT_FLOW__::single_line_messageIds} -show_timestamp ${::__GEN_RESULT_FLOW__::show_timestamp}}]
        optParse $defValDict $defKeyDict $defKeyValDict __reset_config_message_usage__ $args

        if { ${-help} } { __reset_config_message_usage__; __report_message__ "help mode, return" -debug; return }
        if { [dict exists ${-reset_opts_vals_dict} "-single_line_log_style"] } {
            set current_single_line_messageIds [lrange [redirect {get_message_config -single_line_log_style}] 2 end]
            config_message ${current_single_line_messageIds} -single_line_log_style false
            config_message ${::__GEN_RESULT_FLOW__::single_line_messageIds} -single_line_log_style true
        }
        if { [dict exists ${-reset_opts_vals_dict} "-show_timestamp"] } {
            config_message -show_timestamp ${::__GEN_RESULT_FLOW__::show_timestamp}
        }
        __report_message__ "[__print_date__] End to [lindex [info level 0] 0]"
    }

    proc __gen_result_dict_usage__ {} {
        puts "__gen_result_dict__ — 日志消息统计工具"
        puts ""
        puts "用法: __gen_result_dict__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -type <type>        统计类型 (默认 all)"
        puts "                        all     : 同时返回 messagesDict + messageTimesDict"
        puts "                        message : 仅返回 messagesDict"
        puts "                        times   : 仅返回 messageTimesDict"
        puts "  -sortMessage        对 messagesDict 的键按 lsort 排序后返回 (默认不排序)"
        puts "  -stripAbsolutePath  将消息中的绝对路径替换为仅文件名 (默认保留原路径)"
        puts "  -help               打印此用法说明"
        puts ""
        puts "返回值: 嵌套字典，形如:"
        puts "  {messagesDict {...} messageTimesDict {...}}"
        puts ""
        puts "示例:"
        puts "  set r \[__gen_result_dict__ -type all -sortMessage -stripAbsolutePath\]"
        puts "  dict get \$r messagesDict"
        puts "  dict get \$r messageTimesDict"
        puts ""
    }

    proc __gen_result_dict__ {args} {
        if { [catch {current_stage}] } {
            __report_message__ "fail to current_stage" -debug
            return "messagesDict {} messageTimesDict {}"
        } elseif { [regexp "start" [redirect {current_stage}] ] } {
            __report_message__ "current_stage is start, return empty dict" -debug
            return "messagesDict {} messageTimesDict {}"
        }

        set defValDict [dict create]
        set defKeyDict [dict create -help 0 -sortMessage 0 -stripAbsolutePath 0]
        set defKeyValDict [dict create -type all]
        optParse $defValDict $defKeyDict $defKeyValDict __gen_result_dict_usage__ $args

        if { ${-help} } { __gen_result_dict_usage__; __report_message__ "help mode, return empty dict" -debug; return "messagesDict {} messageTimesDict {}" }

        set validTypes [list all message times]
        if { ${-type} ni ${validTypes} } { __report_message__ -severity error "Invalid value, ${-type}, of \"-type\", valid value: [join ${validTypes} {, }]"; return "messagesDict {} messageTimesDict {}" }

        ## try to set the single line log style and without time log
        catch {config_message -single_line_log_style true -show_timestamp false}

        set msgList [split [redirect {report_violation -compressed false}] "\n"]
        # redirect {report_violation -compressed false} -var contents

        __reset_config_message__ -reset_opts_vals_dict {-single_line_log_style ${::__GEN_RESULT_FLOW__::single_line_messageIds} -show_timestamp ${::__GEN_RESULT_FLOW__::show_timestamp}}

        set msgPattern {^(ERROR|WARN|INFO):\s*\(([^\)]+)\):\s*(.*)$}

        set resultDict [dict create]
        set messagesDict [dict create]
        set msgTimesDict [dict create]

        foreach line ${msgList} {
            if { [regexp ${msgPattern} ${line} message level msgId messagebody] } {
                __report_message__ "message: ${message} level: ${level} msgId: ${msgId} messagebody: ${messagebody}" -debug
                if { ${-type} eq "all" || ${-type} eq "message" } {
                    if { ${-stripAbsolutePath} } { set message [__strip_absolute_path__ ${message}]; __report_message__ "strip absolute path: ${message}" -debug }
                    if { ${-sortMessage} } { set message [lsort ${message}]; __report_message__ "sort message: ${message}" -debug }
                    if { ! [dict exists ${messagesDict} ${msgId}] } {
                        dict set messagesDict ${msgId} ${message} 1
                    } else {
                        if { ! [dict exists [dict get ${messagesDict} ${msgId}] ${message}] } {
                            dict set messagesDict ${msgId} ${message} 1
                        } else {
                            set count [expr [dict get [dict get ${messagesDict} ${msgId}] ${message}] + 1]
                            dict set "messagesDict" ${msgId} ${message} ${count}
                        }
                    }
                }
                if { ${-type} eq "all" || ${-type} eq "times" } {
                    dict incr msgTimesDict ${msgId}
                }
            }
        }
        set resultDict [dict create messagesDict ${messagesDict} messageTimesDict ${msgTimesDict}]
        __report_message__ "resultDict: ${resultDict}" -debug

        return ${resultDict}
    }

    proc __gen_dict_result_file_usage__ {} {
        puts "__gen_dict_result_file__ — 生成字典结果文件"
        puts ""
        puts "用法: __gen_dict_result_file__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -dictName <dictName>  字典名称 (默认 tmpResultDictName)"
        puts "  -dict <dict>        字典内容 (默认 {})"
        puts "  -filePath <filePath>  文件路径 (默认 tmpResultDictFile.tcl)"
        puts "  -help               打印此用法说明"
        puts "  -toSplitMsgId       是否按 msgId 分割文件 (默认不分割)"
        puts "  -toSplitMsg         是否按30000条 msg 分割文件 (默认不分割)"
        puts ""
        puts "返回值: 无"
        puts ""
        puts "示例:"
        puts "  __gen_dict_result_file__ -dictName myResultDict -dict {messagesDict {msg1 1 msg2 2} messageTimesDict {msg1 10 msg2 20}} -filePath myResultDictFile.tcl"
        puts "  __gen_dict_result_file__ -dictName myResultDict -dict \${dict} -filePath myResultDictFile.tcl -toSplitMsgId -toSplitMsg"
    }
    proc __gen_dict_result_file__ {args} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."
        set defValDict [dict create]
        set defKeyDict [dict create -help 0 -toSplitMsgId 0 -toSplitMsg 0]
        set defKeyValDict [dict create -dictName "tmpResultDictName" -dict {} -filePath "tmpResultDictFile.tcl"]
        optParse $defValDict $defKeyDict $defKeyValDict __gen_dict_result_file_usage__ $args

        if { ${-help} } { __gen_dict_result_file_usage__; __report_message__ "help mode, return" -debug; return }

        __report_message__ "dictName: ${-dictName}, dict: ${-dict}, filePath: ${-filePath}" -debug

        __backup_file__ ${-filePath}

        set fo [open ${-filePath} "w"]
        if { ! ${-toSplitMsgId} } {
            dict for {k v} ${-dict} {
                puts ${fo} "dict set ${-dictName} ${k} \{${v}\}"
            }
        } else {
            puts ${fo} "set golden_path \[ file dirname \[ file normalize \[ info script \] \] \]"
            dict for {k v} ${-dict} {
                set file_dir [file dirname ${-filePath}]
                set file_tail [file tail ${-filePath}]
                set file_name [file rootname ${file_tail}]
                set file_exp [string trimleft ${file_tail} ${file_name}]

                if { ! ${-toSplitMsg} } {
                    set msg_file_name "${file_name}-${k}${file_exp}"
                    set msg_file "${file_dir}/${msg_file_name}"
                    puts ${fo} "source \${golden_path}/${msg_file_name}"

                    if { [file exists ${msg_file}] } {
                        file delete ${msg_file}
                    }
                    set msg_fo [open ${msg_file} "w"]
                    puts ${msg_fo} "dict set ${-dictName} ${k} \{${v}\}"
                    close ${msg_fo}
                } else {
                    set count 1
                    set file_index 0
                    dict for {message_item message_times} ${v} {
                        if { ${count} == 1 } {
                            incr file_index
                            set msg_file_name "${file_name}-${k}-${file_index}${file_exp}"
                            set msg_file "${file_dir}/${msg_file_name}"
                            puts ${fo} "source \${golden_path}/${msg_file}"

                            if { [file exists ${msg_file}] } { file delete ${msg_file} }
                            set msg_fo [open ${msg_file} "w"]
                        }
                        puts ${msg_fo} "dict set ${-dictName} ${k} \{${message_item}\} ${message_times}"

                        incr count
                        if { ${count} == 30001 } {
                            close ${msg_fo}
                            set count 1
                            unset msg_fo
                        }
                    }
                    if { [info exists msg_fo] } { close ${msg_fo} }
                }
            }
        }
        close ${fo}
        __report_message__ "[__print_date__] End to [lindex [info level 0] 0]"
    }

    proc __compare_messages_dict_usage__ {} {
        puts "__compare_messages_dict__ — 比较两个messages字典结果"
        puts ""
        puts "用法: __compare_messages_dict__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -resultDict <dict>  实际字典内容 (默认 {})"
        puts "  -expectedDict <dict>  期望字典内容 (默认 {})"
        puts "  -csvFile <csvFile>  csv文件路径 (默认 compare_messages_result.csv)"
        puts "  -ignoreMsgIds <list>  忽略的msgId列表 (默认 {})"
        puts "  -ignoreFalseReport  忽略false report (默认 false)"
        puts "  -help               打印此用法说明"
        puts ""
        puts "返回值: 1表示比较成功，0表示比较失败"
        puts ""
        puts "示例:"
        puts "  set flag \[__compare_messages_dict__ -resultDict \$resultDict -expectedDict \$expectedDict -csvFile compare_messages_result.csv\]"
        puts "  if { \$flag } { puts \"compare success\" } else { puts \"compare fail\" }"
        puts ""
    }
    proc __compare_messages_dict__ {args} {
        set defValDict [dict create]
        set defKeyDict [dict create -help 0 -ignoreFalseReport 0]
        set defKeyValDict [dict create -resultDict {} -expectedDict {} -csvFile "compare_messages_result.csv" -ignoreMsgIds {}]
        optParse $defValDict $defKeyDict $defKeyValDict __compare_messages_dict_usage__ $args

        if { ${-help} } { __compare_messages_dict_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "resultDict: ${-resultDict}, expectedDict: ${-expectedDict}, csvFile: ${-csvFile}, ignoreMsgIds: ${-ignoreMsgIds}" -debug

        set flag 1
        set openFile [open ${-csvFile} "w"]
        puts ${openFile} "messageId,message,compare_result,old_times,new_times"

        dict for {messageId messages} ${-resultDict} {
            if { [dict exists ${-expectedDict} ${messageId}] } {
                if { ${messageId} in ${-ignoreMsgIds} } {
                    __report_message__ "ignore message: ${messageId}" -debug
                    puts ${openFile} "${messageId},,ignore_msgId,,"
                    continue
                }

                set expectedMessages [dict get ${-expectedDict} ${messageId}]
                dict for {messageItem messageItemTimes} ${messages} {
                    if { ! [dict exists ${expectedMessages} ${messageItem}] } {
                        __report_message__ "${messageItem}\n-- false report ${messageItemTimes} times." -color red
                        puts ${openFile} "${messageId},[__csv_escape_value__ ${messageItem}],false_report,0,${messageItemTimes}"
                        set flag 0
                    } else {
                        set expectedTimes [dict get ${expectedMessages} ${messageItem}]
                        if { ${expectedTimes} != ${messageItemTimes} } {
                            __report_message__ "${messageItem}\n-- is reported ${messageItemTimes} times, but expected ${expectedTimes} times." -color red
                            puts ${openFile} "${messageId},[__csv_escape_value__ ${messageItem}],fail,${expectedTimes},${messageItemTimes}"
                            set flag 0
                        } else {
                            __report_message__ "${messageItem}\n-- is passed" -debug
                            puts ${openFile} "${messageId},[__csv_escape_value__ ${messageItem}],pass,${expectedTimes},${messageItemTimes}"
                        }
                    }
                }
                dict for {expectedMessageItem expectedMessageTimes} ${expectedMessages} {
                    if { ! [dict exists ${messages} ${expectedMessageItem}] } {
                        __report_message__ "${expectedMessageItem}\n-- missing report ${expectedMessageTimes} times." -color red
                        puts ${openFile} "${messageId},[__csv_escape_value__ ${expectedMessageItem}],missing_report,${expectedMessageTimes},0"
                        set flag 0
                    }
                }
            } else {
                if { ! ${-ignoreFalseReport} } {
                    dict for {messageItem messageItemTimes} ${messages} {
                        __report_message__ "${messageItem}\n-- false report ${messageItemTimes} times." -color red
                        puts ${openFile} "${messageId},[__csv_escape_value__ ${messageItem}],false_report,0,${messageItemTimes}"
                        set flag 0
                    }
                }
            }
        }
        dict for {expectedMessageId expectedMessages} ${-expectedDict} {
            if { ! [dict exists ${-resultDict} ${expectedMessageId}] } {
                dict for {expectedMessageItem expectedMessageTimes} ${expectedMessages} {
                    __report_message__ "${expectedMessageItem}\n-- missing report ${expectedMessageTimes} times." -color red
                    puts ${openFile} "${expectedMessageId},[__csv_escape_value__ ${expectedMessageItem}],missing_report,${expectedMessageTimes},0"
                    set flag 0
                }
            }
        }
        close ${openFile}
        __report_message__ "compare result: ${flag}" -debug
        return ${flag}
    }

    proc __compare_message_times_dict_usage__ {} {
        puts "__compare_message_times_dict__ — 比较两个messageTimes字典结果"
        puts ""
        puts "用法: __compare_message_times_dict__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -resultDict <dict>    实际字典内容 (默认 {})"
        puts "  -expectedDict <dict>  期望字典内容 (默认 {})"
        puts "  -csvFile <csvFile>    csv文件路径 (默认 compare_message_times_result.csv)"
        puts "  -ignoreMsgIds <list>  忽略的msgId列表 (默认 {})"
        puts "  -ignoreFalseReport    忽略false report (默认 false)"
        puts "  -nonTrackChanges      不跟踪变化 (默认 false)"
        puts "  -help                 打印此用法说明"
        puts ""
        puts "返回字典:"
        puts "   flag:                1表示比较成功，0表示比较失败"
        puts "   changes:             包含changed、new、missing三个字典，分别表示变化的msgId、新增的msgId、缺失的msgId"
        puts ""
        puts "示例:"
        puts "  set changes \[__compare_message_times_dict__ -resultDict \$resultDict -expectedDict \$expectedDict -csvFile compare_message_times_result.csv -ignoreMsgIds {msg1 msg2}\]"
        puts "  if { [dict get \$changes flag] } { puts \"compare success\" } else { puts \"compare fail\" }"
        puts ""
    }
    proc __compare_message_times_dict__ {args} {
        set defValDict [dict create]
        set defKeyDict [dict create -help 0 -ignoreFalseReport 0 -nonTrackChanges 0]
        set defKeyValDict [dict create -resultDict {} -expectedDict {} -csvFile "compare_message_times_result.csv" -ignoreMsgIds {}]
        optParse $defValDict $defKeyDict $defKeyValDict __compare_message_times_dict_usage__ $args

        if { ${-help} } { __compare_message_times_dict_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "resultDict: ${-resultDict}, expectedDict: ${-expectedDict}, csvFile: ${-csvFile}, ignoreMsgIds: ${-ignoreMsgIds}, nonTrackChanges: ${-nonTrackChanges}" -debug

        set flag 1
        set openFile [open ${-csvFile} "w"]
        puts ${openFile} "messageId,compare_result,old_times,new_times"

        set changesDict [dict create changed [dict create] new [dict create] missing [dict create]]

        set allMsgIds [lsort -unique [concat [dict keys ${-resultDict}] [dict keys ${-expectedDict}]]]
        foreach msgId ${allMsgIds} {
            if { ${msgId} in ${-ignoreMsgIds} } {
                __report_message__ "ignore message: ${msgId}" -debug
                puts ${openFile} "${msgId},ignore_msgId,,"
                continue
            }

            if { [dict exists ${-expectedDict} ${msgId}] } {
                set expectedTimes [dict get ${-expectedDict} ${msgId}]
                if { [dict exists ${-resultDict} ${msgId}] } {
                    set resultTimes [dict get ${-resultDict} ${msgId}]
                    if { ${expectedTimes} == ${resultTimes} } {
                        __report_message__ "${msgId}\n-- is passed" -debug
                        puts ${openFile} "${msgId},pass,${expectedTimes},${resultTimes}"
                        continue
                    } else {
                        __report_message__ "${msgId}\n-- is reported ${resultTimes} times, but expected ${expectedTimes} times." -color red
                        puts ${openFile} "${msgId},fail,${expectedTimes},${resultTimes}"
                        set flag 0

                        if { ! ${-nonTrackChanges} } {
                            set diff [expr ${resultTimes} - ${expectedTimes}]
                            if { ${diff} > 0 } {
                                dict set changesDict changed ${msgId} +${diff}
                            } else {
                                dict set changesDict changed ${msgId} ${diff}
                            }
                        }
                    }
                } else {
                    if { ${-ignoreFalseReport} } {
                        if { ${expectedTimes} == 0 } {
                            __report_message__ "${msgId} is expected to be reported 0 times" -debug
                            puts ${openFile} "${msgId},pass,0,0"
                            continue
                        }
                    } else {
                        __report_message__ "${msgId} is missing report ${expectedTimes} times." -color red
                        puts ${openFile} "${msgId},fail,${expectedTimes},0"
                        set flag 0

                        if { ! ${-nonTrackChanges} } {
                            dict set changesDict missing ${msgId} -${expectedTimes}
                        }
                    }
                }

            } else {
                if { ! ${-ignoreFalseReport} } {
                    if { [dict exists ${-resultDict} ${msgId}] } {
                        set resultTimes [dict get ${-resultDict} ${msgId}]
                        __report_message__ "${msgId} is false report with ${resultTimes} times." -color red
                        puts ${openFile} "${msgId},fail,0,${resultTimes}"
                        set flag 0

                        if { ! ${-nonTrackChanges} } {
                            dict set changesDict new ${msgId} +${resultTimes}
                        }
                    } else {
                        __report_message__ "${msgId} is invalid check, please check it" -severity error -color red
                        puts ${openFile} "${msgId},invalid_check,,"
                        set flag 0
                        break
                    }
               }
            }
        }
        close ${openFile}
        return [dict create flag ${flag} changes ${changesDict}]
    }

    proc __format_msg_times_changes_to_string_usage__ {} {
        puts "__format_msg_times_changes_to_string__ — 格式化消息次数变化字符串"
        puts ""
        puts "用法: __format_msg_times_changes_to_string__ <changesDict> ?选项...?"
        puts ""
        puts "选项:"
        puts "  <changesDict>        消息次数变化字典 (默认 {})"
        puts "  -lastError <dict>    上一次比较结果字典 (默认 {})"
        puts "  -help                 打印此用法说明"
        puts ""
        puts "返回值: 格式化后的字符串"
        puts ""
    }
    proc __format_msg_times_changes_to_string__ {args} {
        set defValDict [dict create changesDict {}]
        set defKeyDict [dict create -help 0 ]
        set defKeyValDict [dict create -lastError {}]
        optParse $defValDict $defKeyDict $defKeyValDict __format_msg_times_changes_to_string_usage__ $args


        if { ${-help} } { __format_msg_times_changes_to_string_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "changesDict: ${changesDict}, lastError: ${-lastError}" -debug

        set result ""
        proc __filter_changed_dict__ {current_dict last_dict category} {
            if { ${last_dict} eq "" } { return ${current_dict} }

            if { ! [dict exists ${last_dict} ${category}] } {
                return ${current_dict}
            }

            set last_category_dict [dict get ${last_dict} ${category}]
            set filtered_dict [dict create]
            dict for {msgId delta} ${current_dict} {
                if { [dict exists ${last_category_dict} ${msgId}] } {
                    set last_delta [dict get ${last_category_dict} ${msgId}]
                    if { ${delta} != ${last_delta} } {
                        dict set filtered_dict ${msgId} ${delta}
                    }
                } else {
                    dict set filtered_dict ${msgId} ${delta}
                }
            }
            return ${filtered_dict}
        }

        if { [dict exists ${-changesDict} changed] } {
            set changed_dict [dict get ${-changesDict} changed]
        } else {
            set changed_dict [dict create]
        }
        __report_message__ "In proc [lindex [info level 0] 0], changed_dict: ${changed_dict}" -debug
        set changed_dict [__filter_changed_dict__ ${changed_dict} ${-lastError} changed]
        set changed_dict_size [dict size ${changed_dict}]
        if { ${changed_dict_size} > 0 } {
            append result "Changed Messages(${changed_dict_size}): \n"
            dict for {msgId delta} ${changed_dict} {
                append result "\t${msgId}: ${delta}\n"
            }
        }

        set new_dict [dict get ${-changesDict} new]
        __report_message__ "In proc [lindex [info level 0] 0], new_dict: ${new_dict}" -debug
        set new_dict [__filter_changed_dict__ ${new_dict} ${-lastError} new]
        set new_dict_size [dict size ${new_dict}]
        if { ${new_dict_size} > 0 } {
            append result "New Messages(${new_dict_size}): \n"
            dict for {msgId delta} ${new_dict} {
                append result "\t${msgId}: ${delta}\n"
            }
        }

        set missing_dict [dict get ${-changesDict} missing]
        __report_message__ "In proc [lindex [info level 0] 0], missing_dict: ${missing_dict}" -debug
        set missing_dict [__filter_changed_dict__ ${missing_dict} ${-lastError} missing]
        set missing_dict_size [dict size ${missing_dict}]
        if { ${missing_dict_size} > 0 } {
            append result "Missing Messages(${missing_dict_size}): \n"
            dict for {msgId delta} ${missing_dict} {
                append result "\t${msgId}: ${delta}\n"
            }
        }

        __report_message__ "In proc [lindex [info level 0] 0], result: ${result}" -debug
        return ${result}
    }

    proc __gen_command_result_dict_usage__ {} {
        puts "__gen_command_result_dict__ — 生成命令执行结果字典"
        puts ""
        puts "用法: __gen_command_result_dict__ <testCmdDict> ?选项...?"
        puts ""
        puts "选项:"
        puts "  <testCmdDict>        命令执行字典 (默认 {})"
        puts "  -performance         是否性能测试 (默认 false)"
        puts "  -help                打印此用法说明"
        puts ""
        puts "返回值: 命令执行结果字典"
        puts ""
        puts "示例:"
        puts "  __gen_command_result_dict__ \$testCmdDict -performance"
        puts ""
    }
    proc __gen_command_result_dict__ {args} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."
        set defValDict [dict create testCmdDict {}]
        set defKeyDict [dict create -help 0 -performance 0]
        set defKeyValDict [dict create]
        optParse $defValDict $defKeyDict $defKeyValDict __gen_command_result_dict_usage__ $args

        if { ${-help} } { __gen_command_result_dict_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "testCmdDict: ${testCmdDict}, performance: ${-performance}" -debug

        catch {config_message -show_timestamp false}

        set command_result_dict [dict create]
        set qor_info_name_dict [dict create]
        dict for {test_point cmdDict} ${testCmdDict} {
            # valid value:
            #   return  (return value, default)
            #   print   (print information)
            #   number  (number of value)
            set testType "return"
            if { [dict exists ${cmdDict} "testType"] } {
                set testType [dict get ${cmdDict} "testType"]
            }
            if { ${testType} != "print" && ${testType} != "number" && ${testType} != "return" } {
                __report_message__ "Invalid testType value \"$testType\" of ${test_point}, set to the default \"return\" type" -color blue -severity warn
                set testType "return"
            }

            if { ! [dict exists ${cmdDict} "cmd"] } {
                dict set command_result_dict ${test_point} [dict create cmd "" result ""]
                continue
            } else {
                set cmd [dict get ${cmdDict} "cmd"]
                set qor_info_name "${cmd}:${test_point}"
                if { [dict exists ${cmdDict} "qorInfoName"] } {
                    set qor_info_name [dict get ${cmdDict} "qorInfoName"]
                    if { [regexp {^\s*$} ${qor_info_name}] } {
                        set qor_info_name "${cmd}:${test_point}"
                    }
                    if { [dict exists ${qor_info_name_dict} ${qor_info_name}] } {
                        set qor_info_name "${qor_info_name}(${test_point})"
                    }
                }
                dict set qor_info_name_dict ${qor_info_name} ${test_point}

                if { ${-performance} } {
                    if { ${testType} == "print" } {
                        if { [catch {redirect {__QOR_GEN_AND_COMP__::__gen_cmd_qor_result__ ${cmd} ${qor_info_name}} -var cmd_result} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 2]
                            unset catch_msg
                        } else {
                            set cmd_result [__extract_partial_result_str__ ${cmd_result} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${cmd_result}]
                            unset cmd_result catch_msg
                        }
                    } elseif { ${testType} == "number" } {
                        if { [catch {__QOR_GEN_AND_COMP__::__gen_cmd_qor_result__ ${cmd} ${qor_info_name} "" 1} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 1]
                            unset catch_msg
                        } else {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result [llength ${catch_msg}]]
                            unset catch_msg
                        }
                    } else {
                        if { [catch {__QOR_GEN_AND_COMP__::__gen_cmd_qor_result__ ${cmd} ${qor_info_name} "" 1} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 1]
                            unset catch_msg
                        } else {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg}]
                            unset catch_msg
                        }
                    }
                } else {
                    if { ${testType} == "print" } {
                        if { [catch {redirect ${cmd} -var cmd_result} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 2]
                            unset catch_msg
                        } else {
                            set cmd_result [__extract_partial_result_str__ ${cmd_result} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${cmd_result}]
                            unset cmd_result catch_msg
                        }
                    } elseif { ${testType} == "number" } {
                        if { [catch ${cmd} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 1]
                            unset catch_msg
                        } else {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result [llength ${catch_msg}]]
                            unset catch_msg
                        }
                    } else {
                        if { [catch ${cmd} catch_msg] } {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg} error 1]
                            unset catch_msg
                        } else {
                            set catch_msg [__extract_partial_result_str__ ${catch_msg} ${cmdDict}]
                            dict set command_result_dict ${test_point} [dict create cmd ${cmd} result ${catch_msg}]
                            unset catch_msg
                        }
                    }
                }
            }
        }
        ::__GEN_RESULT_FLOW__::__reset_config_message__ -reset_opts_vals_dict {-show_timestamp ${::__GEN_RESULT_FLOW__::show_timestamp}}
        __report_message__ "[__print_date__] End to [lindex [info level 0] 0]."
        return ${command_result_dict}
    }

    proc __compare_command_result_dict_usage__ {} {
        puts "__compare_command_result_dict__ — 比较两个commandResult字典结果"
        puts ""
        puts "用法: __compare_command_result_dict__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -resultDict <dict>    实际字典内容 (默认 {})"
        puts "  -expectedDict <dict>  期望字典内容 (默认 {})"
        puts "  -csvFile <file>      输出csv文件 (默认 compare_command_result.csv)"
        puts "  -nonTrackChanges     是否不记录变化 (默认 false)"
        puts "  -help                打印此用法说明"
        puts ""
        puts "返回字典:"
        puts "  flag:                 1表示成功，0表示失败"
        puts "  failed_commands       失败的命令列表"
        puts ""
        puts "示例:"
    }
    proc __compare_command_result_dict__ {args} {
        __report_message__ "[__print_date__] Start to [lindex [info level 0] 0]..."
        set defValDict [dict create]
        set defKeyDict [dict create -help 0 -nonTrackChanges 0]
        set defKeyValDict [dict create -resultDict {} -expectedDict {} -csvFile "compare_command_result.csv"]
        optParse $defValDict $defKeyDict $defKeyValDict __compare_command_result_dict_usage__ $args

        if { ${-help} } { __compare_command_result_dict_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "resultDict: ${-resultDict}\nexpectedDict: ${-expectedDict}\ncsvFile: ${-csvFile}" -debug

        set flag 1
        set failedCommands [dict create]
        set openFile [open ${-csvFile} w]
        puts ${openFile} "testPoint,old_command,new_command,old_result,new_result,compare_result"
        set allTestPoint [lsort -unique [concat [dict keys ${-resultDict}] [dict keys ${-expectedDict}]]]
        foreach testPoint ${allTestPoint} {
            if { [dict exists ${-expectedDict} ${testPoint}] } {
                set cmdTestpointResultGolden [dict get ${-expectedDict} ${testPoint}]
                if { [dict exists ${cmdTestpointResultGolden} "cmd"] } {
                    set gcmd [dict get ${cmdTestpointResultGolden} "cmd"]
                } else {
                    __report_message__ "testPoint ${testPoint} cannot record the command information by \"cmd\"" -severity error -color red
                    puts ${openFile} "${testPoint},(no cmd information),,,,ignore"
                    set flag 0
                    if { ! ${-nonTrackChanges} } {
                        dict set failedCommands ${testPoint} [dict create cmd "" reason "no cmd information"]
                    }
                    continue
                }
                if { [dict exists ${-resultDict} ${testPoint}] } {
                    set cmdTestpointResult [dict get ${-resultDict} ${testPoint}]
                    set cmd [dict get ${cmdTestpointResult} "cmd"]
                    if { ${cmdTestpointResult} == ${cmdTestpointResultGolden} } {
                        __report_message__ "${testPoint} pass: ${cmd}" -color green -debug
                        puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],[__csv_escape_value__ ${cmdTestpointResultGolden}],[__csv_escape_value__ ${cmdTestpointResult}],pass"
                        continue
                    } else {
                        if { ${cmd} != ${gcmd} } {
                            __report_message__ "${testPoint} fail: the command has been changed.\ngolden command:\n\t${gcmd}\ncurrent command:\n\t${cmd}" -color red
                            puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],[__csv_escape_value__ ${cmdTestpointResultGolden}],[__csv_escape_value__ ${cmdTestpointResult}],fail"
                            set flag 0
                            if { ! ${-nonTrackChanges} } {
                                dict set failedCommands ${testPoint} [dict create cmd ${cmd} reason "command changed"]
                            }
                        } else {
                            if { [dict exists ${cmdTestpointResult} "error"] } {
                                set cmdErrorFlag [dict get ${cmdTestpointResult} "error"]
                            } else {
                                set cmdErrorFlag 0
                            }
                            if { [dict exists ${cmdTestpointResultGolden} "error"] } {
                                set gcmdErrorFlag [dict get ${cmdTestpointResultGolden} "error"]
                            } else {
                                set gcmdErrorFlag 0
                            }

                            set errorFlagPass 0
                            set fail_reason ""
                            switch -regexp "${cmdErrorFlag}${gcmdErrorFlag}" {
                                {(00|11|22)} { set errorFlagPass 1 }
                                01 {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe behavior has been changed: success -> failure" -color red
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],behavior success,behavior failure,fail"
                                    set flag 0
                                    set fail_reason "behavior changed: success -> failure"
                                }
                                02 {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe \"redirect\" behavior has been changed: success -> failure"
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],redirect behavior success,redirect behavior failure,fail"
                                    set flag 0
                                    set fail_reason "redirect behavior changed: success -> failure"
                                }
                                10 {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe behavior has been changed: failure -> success" -color red
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],behavior failure,behavior success,fail"
                                    set flag 0
                                    set fail_reason "behavior changed: failure -> success"
                                }
                                20 {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe \"redirect\" behavior has been changed: failure -> success"
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],redirect behavior failure,redirect behavior success,fail"
                                    set flag 0
                                    set fail_reason "redirect behavior changed: failure -> success"
                                }
                                21 {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe behavior has been changed: success -> failure" -color red
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],behavior success,behavior failure,fail"
                                    set flag 0
                                    set fail_reason "behavior changed: success -> failure"
                                }
                            }
                            if { ! ${errorFlagPass} && ! ${-nonTrackChanges} && ${fail_reason} != "" } {
                                dict set failedCommands ${testPoint} [dict create cmd ${cmd} reason "${fail_reason}"]
                            }
                            if { ${errorFlagPass} } {
                                if { [dict exists ${cmdTestpointResult} "result"] } {
                                    set cmdResult [dict get ${cmdTestpointResult} "result"]
                                } else {
                                    set cmdResult ""
                                }
                                if { [dict exists ${cmdTestpointResultGolden} "result"] } {
                                    set gcmdResult [dict get ${cmdTestpointResultGolden} "result"]
                                } else {
                                    set gcmdResult ""
                                }
                                if { ${cmdResult} == ${gcmdResult} } {
                                    __report_message__ "${testPoint} pass: ${cmd}\n\tthe result and behavior of the command is as expected" -color green -debug
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],[__csv_escape_value__ ${cmdTestpointResultGolden}],[__csv_escape_value__ ${cmdTestpointResult}],pass"
                                    continue
                                } else {
                                    __report_message__ "${testPoint} fail: ${cmd}\n\tgolden result: \n${gcmdResult}\n\tcurrent result: \n${cmdResult}" -color red
                                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],[__csv_escape_value__ ${cmd}],[__csv_escape_value__ ${cmdTestpointResultGolden}],[__csv_escape_value__ ${cmdTestpointResult}],fail"
                                    set flag 0

                                    if { ! ${-nonTrackChanges} } {
                                        dict set failedCommands ${testPoint} [dict create cmd ${cmd} reason {result mismatch}]
                                    }
                                }
                            }
                        }
                    }
                } else {
                    __report_message__ "${testPoint} fail: ${gcmd}\n\tthe test point ${testPoint} is not existed in current, but exists in golden" -color red
                    puts ${openFile} "${testPoint},[__csv_escape_value__ ${gcmd}],,,,fail"
                    set flag 0
                    if { ! ${-nonTrackChanges} } {
                        dict set failedCommands ${testPoint} [dict create cmd ${gcmd} reason {not exists in current}]
                    }
                }
            } else {
                if { [dict exists ${-resultDict} ${testPoint}] } {
                    set cmd [dict get [dict get ${-resultDict} ${testPoint}] "cmd"]
                    __report_message__ "${testPoint} fail: ${cmd}\n\tthe test point ${testPoint} is existed in current, but not exists in golden" -color red
                    puts ${openFile} "${testPoint},,[__csv_escape_value__ ${cmd}],,fail"
                    set flag 0

                    if { ! ${-nonTrackChanges} } {
                        dict set failedCommands ${testPoint} [dict create cmd ${cmd} reason {not exists in golden}]
                    }
                } else {
                    __report_message__ "Invalid check\n\tthe test point ${testPoint} is not existed in current and golden" -color red -severity error
                    puts ${openFile} "${testPoint},,,,,invalid check"
                    set flag 0

                    if { ! ${-nonTrackChanges} } {
                        dict set failedCommands ${testPoint} [dict create cmd {} reason {invalid check}]
                    }
                    break
                }
            }
        }
        close ${openFile}
        __report_message__ "[__print_date__] End to [lindex [info level 0] 0]."
        return [dict create flag ${flag} failed_commands ${failedCommands}]
    }

    proc __format_cmd_failures_to_string_usage__ {} {
        puts "__format_cmd_failures_to_string__ — 格式化命令失败信息"
        puts ""
        puts "用法: __format_cmd_failures_to_string__ ?选项...?"
        puts ""
        puts "选项:"
        puts "  -failed_commands <dict>  命令失败字典内容 (默认 {})"
        puts "  -lastError <dict>      上一次失败信息字典内容 (默认 {})"
        puts "  -help                打印此用法说明"
        puts ""
        puts "返回字符串:"
        puts "  result:                 全量失败信息字符串"
        puts "  issue_result:            只记录变化的失败信息字符串"
        puts ""
    }
    proc __format_cmd_failures_to_string__ {args} {
        set defValDict [dict create failed_commands {}]
        set defKeyDict [dict create -help 0]
        set defKeyValDict [dict create -lastError {}]
        optParse $defValDict $defKeyDict $defKeyValDict __format_cmd_failures_to_string_usage__ $args

        if { ${-help} } { __format_cmd_failures_to_string_usage__; __report_message__ "help mode, return" -debug; return }
        __report_message__ "failed_commands: ${-failed_commands}" -debug

        set result ""

        set failure_count [dict size ${failed_commands}]
        if { ${failure_count} == 0 } {
            return "Failed Commands: 0\n"
        }

        ## result: 全量
        set result "Failed Commands(${failure_count}):\n"

        ## issue_result: 只记录变化
        set issue_result_content ""
        set change_count 0

        dict for {test_point val} ${failed_commands} {
            set cmd [dict get ${val} cmd]
            set reason [dict get ${val} reason]

            set is_changed 1
            if {${-lastError} != {}} {
                if {[dict exists ${-lastError} $test_point]} {
                    set last_reason [dict get [dict get ${-lastError} $test_point] reason]
                    if {$reason == $last_reason} {
                        set is_changed 0
                    }
                }
            }

            set cmd_str "\t${test_point}: ${cmd}\n"
            set reason_str "\t\tReason: ${reason}\n"

            ## 全量都加入 result
            append result $cmd_str $reason_str

            ## 只有变化的才加入 issue_result
            if {$is_changed} {
                append issue_result_content $cmd_str $reason_str
                incr change_count
            }
        }

        ## issue_result 加上正确的标题
        if {$change_count > 0} {
            set issue_result "Failed Commands(${change_count}):\n${issue_result_content}"
        } else {
            set issue_result ""
        }

        ## 返回格式
        if {${-lastError} != {}} {
            return [dict create result $result issue_result $issue_result]
        } else {
            return [dict create result $result issue_result $result]
        }
    }

}