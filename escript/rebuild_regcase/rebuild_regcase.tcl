#!/usr/local/bin/tclsh8.6
#
# rebuild_regcase.tcl
# ---------------------------------------------------------------------------
# Function : Batch modify regression case files IN PLACE.
#            Quickly fix regression failures caused by renamed commands,
#            command options, or option values after tool updates, by
#            rewriting the old tokens to their new legal behavior.
#
#            Supports plain .tcl files and compressed .tar.gz / .tgz archives
#            (the archive is modified in place without leaving an unpacked
#            copy on disk).
#
#            Multiple replacement rules can be applied simultaneously:
#              * KW  : keyword / literal string        -> replacement
#              * KW  : regular expression (with \1 \2 back-references)
#              * CMD : command name                    -> renamed command
#              * OPT : command option (scoped to cmd)  -> renamed option
#              * VAL : command option value (scoped)   -> replaced value
#
#            A multi-thread mode is provided to speed up large case sets.
#
# Require  : common.tcl (namespace __GENERIC_PROCS__)
# Tcl      : tclsh 8.6
# Deps     : gzip, tar available on PATH (only needed for archive handling)
# ---------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Load the pre-existing generic helper procedures.
# --------------------------------------------------------------------------
source [file join [file dirname [info script]] common.tcl]

# Absolute path of this script, reused by worker threads (multi-thread mode).
set ::rebuild_script_path [file normalize [info script]]

###########################################################
# Usage proc
###########################################################
proc USAGE {} {
    puts "Usage: rebuild_regcase.tcl"
    puts "  ( -case <case> | -case_list <file> | -case_dir <dir> )   # at least one"
    puts "   -find <string> -replace <string>      |  -rule_file <file>"
    puts ""
    puts "  -case <case>          One case file to rebuild."
    puts "  -case_list <file>     A file listing case paths, one per line (# comments allowed)."
    puts "  -case_dir <dir>       Recursively collect matching files under <dir>."
    puts "  -find <string>        Keyword / literal string to find (single KW rule)."
    puts "  -replace <string>     Replacement string for -find."
    puts "  -rule_file <file>     File holding multiple replacement rules (Tcl list)."
    puts "  -cmd  {old_cmd new_cmd}            Single CMD rule (command rename)."
    puts "  -opt  {cmd old_opt new_opt}        Single OPT rule (option rename, scoped to cmd)."
    puts "  -val  {cmd opt old_val new_val}    Single VAL rule (option value, scoped to cmd)."
    puts "  -val  {cmd old_val new_val}        Single VAL rule (bare parameter value of cmd)."
    puts "  -suffix_list <list>   Suffixes collected under -case_dir (default: .tcl .tar.gz .tgz)."
    puts "  -archive_suffix_list <list>  Member types modified inside archives (default: .tcl)."
    puts "  -include_str <list>   Only files whose content contains these strings."
    puts "  -logic <and|or>       AND/OR for -include_str (default: and)."
    puts "  -regexp               Treat -find pattern as a regular expression."
    puts "  -nocase               Ignore case when matching."
    puts "  -thread <num>         Number of worker threads (default: 1)."
    puts "  -help                 Show this help."
    puts ""
    puts "Rule file format (a Tcl list of rules, one element per rule):"
    puts "  {KW  <find> <replace>            ?-regexp? ?-nocase?}"
    puts "  {CMD <old_cmd> <new_cmd>         ?-nocase?}"
    puts "      Use an EMPTY new_cmd to DELETE the command AND its whole"
    puts "      argument/option list:  {CMD ABC \"\"}  turns  \[ABC foo -bar 1\]"
    puts "      into  \[\]  (so no dangling parameters are left behind)."
    puts "  {OPT <cmd> <old_opt> <new_opt>   ?-nocase?}"
    puts "  {VAL <cmd> <opt> <old_val> <new_val> ?-nocase?}   # option value"
    puts "  {VAL <cmd> <old_val> <new_val>   ?-nocase?}       # bare parameter value of cmd"
    puts ""
    puts "OPT/VAL replacements are scoped to the line(s) that contain the"
    puts "command token, so keep the command and its options on the same line."
    puts ""
    puts "Multi-value CLI options (-cmd/-opt/-val) take a single Tcl LIST value;"
    puts "brace it, e.g.  -val {do_cmd va va_new}   or   -val {do_new -mode fast slow}."
    puts ""
    puts "Chain rename: after a CMD rename, OPT/VAL rules match the command by"
    puts "EITHER its original or its renamed name. Both forms below are equivalent:"
    puts "  {CMD AA BB}  {OPT AA -a -b}    # matches AA (original name)"
    puts "  {CMD AA BB}  {OPT BB -a -b}    # matches BB (renamed name) -> same result"
    puts "So you may write OPT/VAL rules using whichever command name the file"
    puts "currently contains; the rename and the option/value change can be chained."
}

###########################################################
# proc find_files
# Desc: recursive file finder; supports suffix filter and include-string
#       filter with AND/OR logic.
# Input args:
#   base_dir         root search directory
#   -suffix_list {}  target suffixes, e.g. {.tcl .tar.gz .tgz}
#   -include_str {}  list of strings the file content must contain
#   -logic and|or    combine -include_str with AND (default) or OR
# Return: list of full file paths
###########################################################
proc find_files {base_dir args} {
    set defArgDict [dict create base_dir ${base_dir}]
    set defKeyDict [dict create]
    set defKeyValDict [dict create -suffix_list {.tcl .tar.gz .tgz} -include_str {} -logic "and"]
    __GENERIC_PROCS__::__optParse__ ${defArgDict} ${defKeyDict} ${defKeyValDict} find_files_usage ${args}

    set file_list [list]
    if {![file exists ${base_dir}] || ![file isdirectory ${base_dir}]} {
        __GENERIC_PROCS__::__report_message__ "Directory ${base_dir} not exist or not directory" -severity error
        return ${file_list}
    }

    # Recursive walk using an explicit stack. Avoids glob -recursive, which is
    # not available in every Tcl 8.6 build and is absent from Tcl 8.5.
    set stack [list ${base_dir}]
    while {[llength ${stack}] > 0} {
        set cur [lindex ${stack} end]
        set stack [lrange ${stack} 0 end-1]
        foreach entry [glob -nocomplain -directory ${cur} -types {f d} *] {
            if {[file isdirectory ${entry}]} {
                lappend stack ${entry}
                continue
            }

            set match_suffix 0
            foreach suf ${-suffix_list} {
                if {[string match "*${suf}" ${entry}]} {
                    set match_suffix 1
                    break
                }
            }
            if {!${match_suffix}} {
                continue
            }

            set pass_include 1
            if {[llength ${-include_str}] > 0} {
                set content_ok 0
                if {[file readable ${entry}]} {
                    if {[catch {
                        set fd [open ${entry} r]
                        fconfigure ${fd} -translation binary -encoding binary
                        set content [read ${fd}]
                        close ${fd}
                    } err]} {
                        set content_ok 0
                    } else {
                        set hit_count 0
                        foreach s ${-include_str} {
                            if {[string first ${s} ${content}] != -1} {
                                incr hit_count
                            }
                        }
                        if {${-logic} eq "and"} {
                            set content_ok [expr {${hit_count} == [llength ${-include_str}]}]
                        } else {
                            set content_ok [expr {${hit_count} > 0}]
                        }
                    }
                }
                set pass_include ${content_ok}
            }

            if {${pass_include}} {
                lappend file_list ${entry}
            }
        }
    }
    return ${file_list}
}

proc find_files_usage {} {
    puts "Usage: find_files <base_dir> \[-suffix_list {s1 s2}\] \[-include_str {s1 s2}\] \[-logic and|or\]"
}

###########################################################
# proc escape_regex
# Desc: escape Tcl regular-expression metacharacters in a literal string.
###########################################################
proc escape_regex {str} {
    set special "\\$^.|?*+()\[\]{}"
    set out ""
    foreach c [split ${str} ""] {
        if {[string first ${c} ${special}] >= 0} {
            append out "\\" ${c}
        } else {
            append out ${c}
        }
    }
    return ${out}
}

###########################################################
# proc rebuild_del_braced
# Desc: delete a braced script (catch/redirect/eval/uplevel)
#       whose body starts with the command. Brace depth is
#       counted manually; the script brace is located by
#       position so the Tcl source stays free of brace literals.
###########################################################
proc rebuild_del_braced {content cmd_re nocase} {
    set _lt {(\m(?:catch|redirect|eval|uplevel)\M(?:[ \t]+[^\s()[\]\x7b\x7d]+)*[ \t]*)}
    set lead ${_lt}
    set result $content
    set offset 0
    while {1} {
        if {$nocase} {
            set m [regexp -nocase -start $offset -indices -- $lead $result whole]
        } else {
            set m [regexp -start $offset -indices -- $lead $result whole]
        }
        if {!$m} break
        set bracePos [expr {[lindex $whole 1] + 1}]
        set depth 0
        set j $bracePos
        set n [string length $result]
        set close -1
        while {$j < $n} {
            set ch [string index $result $j]
            set cc [scan ${ch} %c]
            if {${cc} == 123} {
                incr depth
            } elseif {${cc} == 125} {
                incr depth -1
                if {$depth == 0} { set close $j; break }
            }
            incr j
        }
        if {$close < 0} {
            set offset [expr {[lindex $whole 0] + 1}]
            continue
        }
        set body [string range $result [expr {$bracePos + 1}] [expr {$close - 1}]]
        set body2 [string trimleft $body " \t\n\r\f\v"]
        if {$nocase} {
            set hit [regexp -nocase "^$cmd_re" $body2]
        } else {
            set hit [regexp "^$cmd_re" $body2]
        }
        if {$hit} {
            set result [string replace $result $bracePos $close "\{\}"]
            set offset [expr {$bracePos + 2}]
        } else {
            set offset [expr {[lindex $whole 0] + 1}]
        }
    }
    return $result
}

###########################################################
# proc rebuild_del_set
# Desc: delete a set VAR "..." / set VAR {...} command value
#       when VAR names a command variable (cmd/command/script).
#       The delimiter is located by position; braces are counted
#       manually. Source is free of literal brace characters.
###########################################################
proc rebuild_del_set {content cmd_re nocase} {
    set _lt {(\mset\M[ \t]+)(\w+)([ \t]+)}
    set result $content
    set offset 0
    while {1} {
        if {$nocase} {
            set m [regexp -nocase -start $offset -indices -- $_lt $result whole g1 g2]
        } else {
            set m [regexp -start $offset -indices -- $_lt $result whole g1 g2]
        }
        if {!$m} break
        set varname [string range $result [lindex $g2 0] [lindex $g2 1]]
        if {![regexp -nocase {(?:^|_)(?:cmd|command|script)(?:_|$)} $varname]} {
            set offset [expr {[lindex $whole 0] + 1}]
            continue
        }
        set delimIdx [expr {[lindex $whole 1] + 1}]
        set delim [string index $result $delimIdx]
        set valStart [expr {$delimIdx + 1}]
        set n [string length $result]
        set close -1
        if {$delim eq "\""} {
            set k $valStart
            while {$k < $n} {
                set ch [string index $result $k]
                if {$ch eq "\\"} { incr k 2; continue }
                if {$ch eq "\""} { set close $k; break }
                incr k
            }
            if {$close < 0} { set offset [expr {[lindex $whole 0] + 1}]; continue }
            set valEnd [expr {$close - 1}]
            set repl "\"\""
        } else {
            set depth 0
            set j $delimIdx
            while {$j < $n} {
                set ch [string index $result $j]
                set cc [scan ${ch} %c]
                if {${cc} == 123} { incr depth } elseif {${cc} == 125} { incr depth -1; if {$depth==0} {set close $j; break} }
                incr j
            }
            if {$close < 0} { set offset [expr {[lindex $whole 0] + 1}]; continue }
            set valEnd [expr {$close - 1}]
            set repl "\{\}"
        }
        set value [string range $result $valStart $valEnd]
        set vcheck [string trimleft $value " \t\n\r\f\v"]
        if {$nocase} {
            set hit [regexp -nocase "^$cmd_re" $vcheck]
        } else {
            set hit [regexp "^$cmd_re" $vcheck]
        }
        if {$hit} {
            set result [string replace $result $delimIdx $close $repl]
            set offset [expr {$delimIdx + [string length $repl]}]
        } else {
            set offset [expr {[lindex $whole 0] + 1}]
        }
    }
    return $result
}

# ===========================================================================
# Command-structure-aware replacement helpers (OPT / VAL scoping fix)
#
# The old OPT/VAL code matched the option/value with a regex on the WHOLE
# line whenever the line contained the target command. That rewrote tokens
# belonging to OTHER commands (e.g. rule {OPT cmdB -a -b} changed cmdA's -a
# inside "cmdA -a [cmdB -a b]") and could even rewrite a value that merely
# looked like the option.
#
# The walkers below locate each INVOCATION of the target command and operate
# only on that invocation's own top-level argument tokens. Nested [..] {..}
# ".." units are treated as opaque (recursed into only to find further
# invocations of the same command), so a token inside a nested command is
# never mistaken for the outer command's argument.
# ===========================================================================

# Find the matching close delimiter. openIdx points at the OPEN char
# ([ { or "). closeCode: 93 for ], 125 for }, 34 for ".
# Nesting of [ { } ] and quotes is tracked so a delimiter inside a
# different grouping is ignored.
proc rebuild_find_close {str openIdx closeCode} {
    set n [string length $str]
    set openC [scan [string index $str $openIdx] %c]
    if {$closeCode == 34} {
        set j [expr {$openIdx + 1}]
        while {$j < $n} {
            set c [string index $str $j]
            if {$c eq "\x5c"} { incr j 2; continue }
            if {$c eq "\x22"} { return $j }
            incr j
        }
        return -1
    }
    set depth 1
    set inBrace 0
    set inBrack 0
    set inQuote 0
    set j [expr {$openIdx + 1}]
    while {$j < $n} {
        set c [string index $str $j]
        set cc [scan $c %c]
        if {$inQuote} {
            if {$c eq "\x5c"} { incr j 2; continue }
            if {$cc == 34} { set inQuote 0 }
            incr j; continue
        }
        if {$inBrace > 0} {
            if {$cc == 123} { incr inBrace } elseif {$cc == 125} { incr inBrace -1 }
            incr j; continue
        }
        if {$inBrack > 0} {
            if {$cc == 91} { incr inBrack } elseif {$cc == 93} { incr inBrack -1 }
            incr j; continue
        }
        if {$cc == 123} { incr inBrace; incr j; continue }
        if {$cc == 91} { incr inBrack; incr j; continue }
        if {$cc == 34} { set inQuote 1; incr j; continue }
        if {$cc == $openC} { incr depth } elseif {$cc == $closeCode} { incr depth -1; if {$depth == 0} { return $j } }
        incr j
    }
    return -1
}

# Return 1 if the brace at braceIdx opens a SCRIPT body (preceded by one of
# catch/redirect/eval/uplevel), else 0 (a literal braced value).
proc rebuild_is_script_brace {str braceIdx} {
    set k $braceIdx
    while {$k > 0} {
        set pc [string index $str [expr {$k-1}]]
        if {[string is space $pc]} { incr k -1; continue }
        break
    }
    set wstart $k
    while {$wstart > 0} {
        set c [string index $str [expr {$wstart-1}]]
        if {[string is space $c]} { break }
        incr wstart -1
    }
    set word [string range $str $wstart [expr {$k-1}]]
    if {[lsearch -exact {catch redirect eval uplevel} $word] >= 0} { return 1 }
    return 0
}

# Read one maximal word starting at i. Nested [ { " units are jumped over
# (treated as a single atomic word). Returns [word endIdx].
proc rebuild_read_word {str i} {
    set n [string length $str]
    set start $i
    while {$i < $n} {
        set c [string index $str $i]
        set cc [scan $c %c]
        if {[string is space $c]} { break }
        if {$cc == 91} {
            set close [rebuild_find_close $str $i 93]
            if {$close < 0} { set i $n; break }
            set i [expr {$close + 1}]; continue
        }
        if {$cc == 123} {
            set close [rebuild_find_close $str $i 125]
            if {$close < 0} { set i $n; break }
            set i [expr {$close + 1}]; continue
        }
        if {$cc == 34} {
            set close [rebuild_find_close $str $i 34]
            if {$close < 0} { set i $n; break }
            set i [expr {$close + 1}]; continue
        }
        incr i
    }
    return [list [string range $str $start [expr {$i - 1}]] $i]
}

# True if position i is a command position within the current scope
# (scopeStart .. i), i.e. i is the scope start or preceded (ignoring
# whitespace) by ; or newline.
proc rebuild_at_cmd_pos {str i scopeStart} {
    if {$i <= $scopeStart} { return 1 }
    set k $i
    while {$k > $scopeStart} {
        set c [string index $str [expr {$k-1}]]
        if {[string is space $c]} { incr k -1; continue }
        if {$c eq ";"} { return 1 }
        if {$c eq "\n"} {
            # A newline (optionally preceded by \r on CRLF files) right after a
            # backslash is a Tcl line continuation, NOT a command boundary.
            set b1 [expr {$k-2}]
            if {$b1 >= $scopeStart && [string index $str $b1] eq "\r"} {
                set bk [expr {$k-3}]
            } else {
                set bk [expr {$k-2}]
            }
            if {$bk >= $scopeStart && [string index $str $bk] eq "\\"} { return 0 }
            return 1
        }
        return 0
    }
    return 1
}

proc rebuild_word_eq {a b nocase} {
    if {$nocase} { return [expr {[string tolower $a] eq [string tolower $b]}] }
    return [expr {$a eq $b}]
}

# If the command at position i (one of cmd_list, possibly a multi-word
# name joined by _) matches, return [endIdx commandText]; else [0 ""].
proc rebuild_cmd_span {str i scopeStart cmd_list nocase} {
    set words [list]
    set pos $i
    set n [string length $str]
    for {set k 0} {$k < 3} {incr k} {
        while {$pos < $n && [string is space [string index $str $pos]]} { incr pos }
        if {$pos >= $n} break
        lassign [rebuild_read_word $str $pos] w j
        if {$w eq ""} break
        lappend words $w
        set joined [join $words "_"]
        foreach c $cmd_list {
            if {[rebuild_word_eq $joined $c $nocase]} { return [list $j [join $words " "]] }
        }
        set pos $j
    }
    return [list 0 ""]
}

# ---- OPT walker ----
proc rebuild_opt_walk {str cmd_list oldopt newopt nocase renameMode scopeStart} {
    set scriptCmds {catch redirect eval uplevel}
    set out ""
    set i $scopeStart
    set n [string length $str]
    set prevOpt 0
    set firstArg 1
    set lastCmd ""
    set scriptCtx 0
    while {$i < $n} {
        set c [string index $str $i]
        set cc [scan $c %c]
        if {[string is space $c]} { append out $c; incr i; continue }
        if {$cc == 92} {
            # backslash: line continuation only if immediately followed by
            # newline (LF or CRLF). Preserve the original formatting and keep
            # the current command scope intact.
            set nxt [string index $str [expr {$i+1}]]
            if {$nxt eq "\n"} {
                append out "\\\n"; set i [expr {$i+2}]; continue
            }
            if {$nxt eq "\r" && [string index $str [expr {$i+2}]] eq "\n"} {
                append out "\\\r\n"; set i [expr {$i+3}]; continue
            }
        }
        if {$c eq "\n" || $c eq ";"} {
            append out $c; incr i
            if {$renameMode} { set renameMode 0; set prevOpt 0; set firstArg 1; set pendingOpt 0 }
            continue
        }
        if {$cc == 91} {
            set close [rebuild_find_close $str $i 93]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            append out "\x5b" [lindex [rebuild_opt_walk $inner $cmd_list $oldopt $newopt $nocase 0 0] 0] "\x5d"
            set i [expr {$close+1}]; set prevOpt 0; continue
        }
        if {$cc == 123} {
            set scriptP [rebuild_is_script_brace $str $i]
            set close [rebuild_find_close $str $i 125]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            if {$scriptP} {
                append out "\x7b" [lindex [rebuild_opt_walk $inner $cmd_list $oldopt $newopt $nocase 0 0] 0] "\x7d"
            } else {
                append out "\x7b" $inner "\x7d"
            }
            set i [expr {$close+1}]; set prevOpt 0; continue
        }
        if {$cc == 34} {
            set close [rebuild_find_close $str $i 34]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            if {$scriptCtx} {
                append out "\x22" [lindex [rebuild_opt_walk $inner $cmd_list $oldopt $newopt $nocase 0 0] 0] "\x22"
            } else {
                append out "\x22" [rebuild_opt_walk_quoted $inner $cmd_list $oldopt $newopt $nocase] "\x22"
            }
            set i [expr {$close+1}]; set prevOpt 0; continue
        }
        lassign [rebuild_read_word $str $i] word j
        if {!$renameMode && [rebuild_at_cmd_pos $str $i $scopeStart]} {
            lassign [rebuild_cmd_span $str $i $scopeStart $cmd_list $nocase] cEnd cText
            if {$cEnd > 0} {
                set lastCmd $cText
                set scriptCtx [expr {[lsearch -exact $scriptCmds $cText] >= 0}]
                append out $cText
                set i $cEnd
                set renameMode 1; set firstArg 1; set prevOpt 0
                continue
            }
            set lastCmd $word
            set scriptCtx [expr {[lsearch -exact $scriptCmds $word] >= 0}]
        }
        set isOpt [expr {[string index $word 0] eq "\x2d"}]
        # Within the target command's scope (renameMode), ANY token that starts
        # with "-" and matches the old option is an option of that command and
        # is renamed. We deliberately do NOT require it to immediately follow
        # another option: in option-value commands like `cmdB -name foo -a x`
        # (often split across line continuations) the target option follows a
        # previous option's VALUE, yet it is still an option and must be renamed.
        # Cross-command isolation is already guaranteed by renameMode.
        if {$renameMode && $isOpt && [rebuild_word_eq $word $oldopt $nocase]} {
            set word $newopt
        }
        append out $word
        set i $j
        if {$renameMode} { set prevOpt $isOpt; set firstArg 0 }
    }
    return [list $out $n]
}

# Quoted-string interior: only [..] command substitutions are command
# contexts; everything else is literal text.
proc rebuild_opt_walk_quoted {str cmd_list oldopt newopt nocase} {
    set out ""
    set i 0
    set n [string length $str]
    while {$i < $n} {
        set c [string index $str $i]
        set cc [scan $c %c]
        if {$cc == 91} {
            set close [rebuild_find_close $str $i 93]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            append out "\x5b" [lindex [rebuild_opt_walk $inner $cmd_list $oldopt $newopt $nocase 0 0] 0] "\x5d"
            set i [expr {$close+1}]; continue
        }
        append out $c; incr i
    }
    return $out
}

proc rebuild_opt_apply {content cmd_list oldopt newopt nocase} {
    lassign [rebuild_opt_walk $content $cmd_list $oldopt $newopt $nocase 0 0] content _
    return $content
}

# ---- VAL walker ----
proc rebuild_val_walk {str cmd_list is_opt_form val_opt oldval newval nocase renameMode scopeStart} {
    set out ""
    set i $scopeStart
    set n [string length $str]
    set prevOpt 0
    set firstArg 1
    set pendingOpt 0
    set scriptCmds {catch redirect eval uplevel}
    set lastCmd ""
    set scriptCtx 0
    while {$i < $n} {
        set c [string index $str $i]
        set cc [scan $c %c]
        if {[string is space $c]} { append out $c; incr i; continue }
        if {$cc == 92} {
            # backslash: line continuation only if immediately followed by
            # newline (LF or CRLF). Preserve the original formatting and keep
            # the current command scope intact.
            set nxt [string index $str [expr {$i+1}]]
            if {$nxt eq "\n"} {
                append out "\\\n"; set i [expr {$i+2}]; continue
            }
            if {$nxt eq "\r" && [string index $str [expr {$i+2}]] eq "\n"} {
                append out "\\\r\n"; set i [expr {$i+3}]; continue
            }
        }
        if {$c eq "\n" || $c eq ";"} {
            append out $c; incr i
            if {$renameMode} { set renameMode 0; set prevOpt 0; set firstArg 1; set pendingOpt 0 }
            continue
        }
        if {$cc == 91} {
            set close [rebuild_find_close $str $i 93]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            append out "\x5b" [lindex [rebuild_val_walk $inner $cmd_list $is_opt_form $val_opt $oldval $newval $nocase 0 0] 0] "\x5d"
            set i [expr {$close+1}]; set prevOpt 0; set pendingOpt 0; continue
        }
        if {$cc == 123} {
            set scriptP [rebuild_is_script_brace $str $i]
            set close [rebuild_find_close $str $i 125]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            if {$scriptP} {
                append out "\x7b" [lindex [rebuild_val_walk $inner $cmd_list $is_opt_form $val_opt $oldval $newval $nocase 0 0] 0] "\x7d"
            } else {
                append out "\x7b" $inner "\x7d"
            }
            set i [expr {$close+1}]; set prevOpt 0; set pendingOpt 0; continue
        }
        if {$cc == 34} {
            set close [rebuild_find_close $str $i 34]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            if {$scriptCtx} {
                append out "\x22" [lindex [rebuild_val_walk $inner $cmd_list $is_opt_form $val_opt $oldval $newval $nocase 0 0] 0] "\x22"
            } else {
                append out "\x22" [rebuild_val_walk_quoted $inner $cmd_list $is_opt_form $val_opt $oldval $newval $nocase] "\x22"
            }
            set i [expr {$close+1}]; set prevOpt 0; set pendingOpt 0; continue
        }
        lassign [rebuild_read_word $str $i] word j
        if {!$renameMode && [rebuild_at_cmd_pos $str $i $scopeStart]} {
            lassign [rebuild_cmd_span $str $i $scopeStart $cmd_list $nocase] cEnd cText
            if {$cEnd > 0} {
                set lastCmd $cText
                set scriptCtx [expr {[lsearch -exact $scriptCmds $cText] >= 0}]
                append out $cText
                if {!$is_opt_form && $oldval eq ""} { append out " " $newval }
                set i $cEnd
                set renameMode 1; set firstArg 1; set prevOpt 0; set pendingOpt 0
                continue
            }
            set lastCmd $word
            set scriptCtx [expr {[lsearch -exact $scriptCmds $word] >= 0}]
        }
        set isOpt [expr {[string index $word 0] eq "\x2d"}]
        set emit $word
        if {$renameMode} {
            if {$is_opt_form} {
                if {$pendingOpt} {
                    if {$oldval ne "" && [rebuild_word_eq $word $oldval $nocase]} {
                        set emit $newval
                    }
                    set pendingOpt 0
                } elseif {$isOpt && [rebuild_word_eq $word $val_opt $nocase]} {
                    set pendingOpt 1
                    if {$oldval eq ""} {
                        append out $word " " $newval
                        set pendingOpt 0
                        set i $j; set prevOpt $isOpt; set firstArg 0
                        continue
                    }
                }
            } else {
                if {!$isOpt && $oldval ne "" && [rebuild_word_eq $word $oldval $nocase]} {
                    set emit $newval
                }
            }
            set prevOpt $isOpt
            set firstArg 0
        }
        append out $emit
        set i $j
    }
    return [list $out $n]
}

proc rebuild_val_walk_quoted {str cmd_list is_opt_form val_opt oldval newval nocase} {
    set out ""
    set i 0
    set n [string length $str]
    while {$i < $n} {
        set c [string index $str $i]
        set cc [scan $c %c]
        if {$cc == 91} {
            set close [rebuild_find_close $str $i 93]
            if {$close < 0} { append out $c; incr i; continue }
            set inner [string range $str [expr {$i+1}] [expr {$close-1}]]
            append out "\x5b" [lindex [rebuild_val_walk $inner $cmd_list $is_opt_form $val_opt $oldval $newval $nocase 0 0] 0] "\x5d"
            set i [expr {$close+1}]; continue
        }
        append out $c; incr i
    }
    return $out
}

proc rebuild_val_apply {content cmd_list is_opt_form val_opt oldval newval nocase} {
    lassign [rebuild_val_walk $content $cmd_list $is_opt_form $val_opt $oldval $newval $nocase 0 0] content _
    return $content
}

###########################################################
# proc apply_one_rule
# Desc: apply a single replacement rule to the content string.
#       Returns the new content string.
###########################################################
proc apply_one_rule {content type rule_regexp rule_nocase args} {
    switch -exact -- ${type} {
        KW {
            lassign ${args} find repl
            if {${rule_regexp}} {
                if {${rule_nocase}} {
                    regsub -all -nocase -- ${find} ${content} ${repl} content
                } else {
                    regsub -all -- ${find} ${content} ${repl} content
                }
            } elseif {${rule_nocase}} {
                set pat [escape_regex ${find}]
                regsub -all -nocase -- ${pat} ${content} ${repl} content
            } else {
                set content [string map [list ${find} ${repl}] ${content}]
            }
        }
        CMD {
            lassign ${args} oldcmd newcmd
            if {${newcmd} eq ""} {
                # --- Delete command AND its full argument/option list ---
                # Rule CMD ABC empty removes the ENTIRE invocation of ABC in
                # every call form it can appear:
                #   [ABC args]                       -> []   (bracketed call)
                #   (ABC args)                       -> ()   (parenthesised call)
                #   AAA args                         -> gone (bare cmd at stmt start)
                #   catch/redirect/eval/uplevel BRACE AAA BRACE -> ... BRACE BRACE (braced script)
                #   catch/redirect/eval/uplevel "AAA" -> ... ""  (quoted script)
                #   set VAR "AAA.." / BRACE AAA.. BRACE -> ... "" / BRACE BRACE (cmd stored in a var)
                # ABC that is merely an ARGUMENT to another command, or a STRING
                # literal, is left untouched to avoid creating other garbage.
                # Regex templates are DOUBLE-QUOTED: inside "..." Tcl does not
                # count braces, every regex [ is escaped as \[ (no command sub),
                # and every regex backslash is written as \\.
                set wordpat [string cat {\m} [escape_regex ${oldcmd}] {\M}]
                set _tpl_b  [string map [list __WORD__ ${wordpat}] {\[[ \t]*__WORD__(?:[ \t]+[^\]\[;]+)?[ \t]*\]}]
                set _tpl_p  [string map [list __WORD__ ${wordpat}] {\([ \t]*__WORD__(?:[ \t]+[^\(\);]+)?[ \t]*\)}]
                set _tpl_s  [string map [list __WORD__ ${wordpat}] {((?:^|\n|;))[ \t]*__WORD__(?:[ \t]+[^\n;()[\]\x7b\x7d]+)?[ \t]*}]
                set _tpl_q  [string map [list __WORD__ ${wordpat}] {(\m(?:catch|redirect|eval|uplevel)\M(?:[ \t]+[^\s"()[\]\x7b\x7d]+)*[ \t]+)"__WORD__[^"]*"}]
                if {${rule_nocase}} {
                    regsub -all -nocase -- ${_tpl_b}  ${content} {[]}  content
                    regsub -all -nocase -- ${_tpl_p}  ${content} {()}  content
                    regsub -all -nocase -- ${_tpl_s}  ${content} {\1}  content
                    regsub -all -nocase -- ${_tpl_q}  ${content} {\1""} content
                } else {
                    regsub -all -- ${_tpl_b}  ${content} {[]}  content
                    regsub -all -- ${_tpl_p}  ${content} {()}  content
                    regsub -all -- ${_tpl_s}  ${content} {\1}  content
                    regsub -all -- ${_tpl_q}  ${content} {\1""} content
                }
                set content [rebuild_del_braced ${content} ${wordpat} ${rule_nocase}]
                set content [rebuild_del_set    ${content} ${wordpat} ${rule_nocase}]
            } else {
                set pat "\\m[escape_regex ${oldcmd}]\\M"
                if {${rule_nocase}} {
                    regsub -all -nocase -- ${pat} ${content} ${newcmd} content
                } else {
                    regsub -all -- ${pat} ${content} ${newcmd} content
                }
            }
        }
        OPT {
            lassign ${args} cmd oldopt newopt
            # cmd may be a single name or an alias list (original + renamed
            # forms from chain-rename). Expand to a command-name list so any
            # of them is matched as the target command.
            if {[llength ${cmd}] > 1} {
                set cmd_list ${cmd}
            } else {
                set cmd_list [list ${cmd}]
            }
            # Command-scoped, token-aware option rename: only rename oldopt
            # when it is an OPTION of the target command (first argument token
            # or immediately following another option), never a value and
            # never an option belonging to a different command on the same line.
            set content [rebuild_opt_apply ${content} ${cmd_list} ${oldopt} ${newopt} ${rule_nocase}]
        }
        VAL {
            # ----------------------------------------------------------------
            # VAL rule replaces a value scoped to lines containing <cmd>.
            # Two forms:
            #   4-arg: {VAL cmd opt oldval newval}  — option-value form
            #   3-arg: {VAL cmd oldval newval}      — bare parameter form
            #
            # The command name (<cmd>) may contain spaces (e.g. "gui get
            # component" for gui_get_component).  When more than 3/4 args are
            # present, leading elements are joined to form the command name.
            #
            # Special handling when <oldval> is empty (""): this means "insert
            # <newval> as an argument where the command (or option) appears
            # WITHOUT an existing value".  Instead of the broken regex
            # (\W|^)(\W|$) which matches every non-word boundary, we match
            # the specific pattern: command/option followed only by
            # whitespace and a closing bracket ] ) or end-of-line.
            # ----------------------------------------------------------------
            set n [llength ${args}]

            # --- Determine arity, extract fields, handle multi-word cmd ---
            set val_cmd {}          ;# command name (possibly multi-word)
            set val_opt {}          ;# option name (4-arg / option form only)
            set oldval ""           ;# value to find
            set newval ""           ;# replacement value
            set is_opt_form 0       ;# 1 = option-value form, 0 = bare param

            if {${n} == 3} {
                lassign ${args} val_cmd oldval newval
            } elseif {${n} == 4} {
                # Ambiguous: could be {cmd opt oldval newval} or
                # {word1 word2 oldval newval}.  Heuristic: if arg[1] starts
                # with "-" treat it as an option flag.
                set a1 [lindex ${args} 1]
                if {[string index ${a1} 0] eq "-"} {
                    set is_opt_form 1
                    lassign ${args} val_cmd val_opt oldval newval
                } else {
                    set val_cmd [join [lrange ${args} 0 1] "_"]
                    set oldval [lindex ${args} 2]
                    set newval [lindex ${args} 3]
                }
            } elseif {${n} >= 5} {
                # Multi-word command name.  Determine option-form vs bare
                # by checking whether the element at position (n-4) starts
                # with "-".
                set split_at [expr {${n} - 4}]
                if {[string index [lindex ${args} ${split_at}] 0] eq "-"} {
                    # Option form: cmd = args[0..split_at-1], opt = args[split_at]
                    set is_opt_form 1
                    set val_cmd [join [lrange ${args} 0 ${split_at}-1] "_"]
                    set val_opt  [lindex ${args} ${split_at}]
                    set oldval  [lindex ${args} ${split_at}+1]
                    set newval  [lindex ${args} ${split_at}+2]
                } else {
                    # Bare form: cmd = first (n-3) elements joined with '_'
                    #            (so "gui get component" -> "gui_get_component"),
                    #            oldval = args[n-2], newval = args[n-1]
                    set val_cmd [join [lrange ${args} 0 ${n}-3] "_"]
                    set oldval  [lindex ${args} ${n}-2]
                    set newval  [lindex ${args} ${n}-1]
                }
            } else {
                __GENERIC_PROCS__::__report_message__ \
                    "VAL rule needs 3 (cmd val val_new) or 4 (cmd opt val val_new) fields, got ${n}" \
                    -severity warn
                return ${content}
            }

            # --- Command-scoped value replacement (walker-based) ---
            # Build the command-name list. val_cmd may be a single joined
            # string (multi-word command) or an alias list (from chain-rename
            # expansion).
            if {[llength ${val_cmd}] > 1} {
                set cmd_list ${val_cmd}
            } else {
                set cmd_list [list ${val_cmd}]
            }
            # The walker operates only inside the target command's own
            # argument tokens, so a value belonging to a different command
            # (or nested in another invocation) is never touched.
            set content [rebuild_val_apply ${content} ${cmd_list} ${is_opt_form} ${val_opt} ${oldval} ${newval} ${rule_nocase}]
        }
        default {
            __GENERIC_PROCS__::__report_message__ "Unknown rule type: ${type}" -severity warn
        }
    }
    return ${content}
}

###########################################################
# proc build_cmd_aliases
# Desc: collect CMD rename rules and build an equivalence table so that
#       OPT/VAL rules can match a command by EITHER its original name or
#       any of its renamed forms (chain-rename support).
#       Example: {CMD AA BB} makes "AA" and "BB" equivalent, so both
#                {OPT AA -a -b} and {OPT BB -a -b} match the same lines.
#       Returns a dict: cmd_name -> list_of_equivalent_names
###########################################################
proc build_cmd_aliases {rules} {
    # Collect (old new) edges from every CMD rule.
    set edges [list]
    foreach rule ${rules} {
        if {[lindex ${rule} 0] eq "CMD"} {
            lassign ${rule} _ old new
            if {${old} ne "" && ${new} ne ""} {
                lappend edges [list ${old} ${new}]
            }
        }
    }

    # Union-find style grouping: names connected through CMD renames belong
    # to the same equivalence group.
    set groups [list]
    foreach e ${edges} {
        lassign ${e} a b
        set ga -1
        set gb -1
        set gi 0
        foreach g ${groups} {
            if {${ga} == -1 && [lsearch -exact ${g} ${a}] >= 0} { set ga ${gi} }
            if {${gb} == -1 && [lsearch -exact ${g} ${b}] >= 0} { set gb ${gi} }
            incr gi
        }
        if {${ga} == -1 && ${gb} == -1} {
            lappend groups [list ${a} ${b}]
        } elseif {${ga} == -1} {
            lset groups ${gb} [linsert [lindex ${groups} ${gb}] end ${a}]
        } elseif {${gb} == -1} {
            lset groups ${ga} [linsert [lindex ${groups} ${ga}] end ${b}]
        } else {
            set merged [concat [lindex ${groups} ${ga}] [lindex ${groups} ${gb}]]
            set gi_sorted [lsort -integer -decreasing [list ${ga} ${gb}]]
            foreach idx ${gi_sorted} { set groups [lreplace ${groups} ${idx} ${idx}] }
            lappend groups ${merged}
        }
    }

    # Build name -> group dict.
    set alias_map [dict create]
    foreach g ${groups} {
        foreach name ${g} {
            dict set alias_map ${name} ${g}
        }
    }
    return ${alias_map}
}

###########################################################
# proc apply_rules
# Desc: apply all replacement rules sequentially.
#       Returns a list: {new_content changed_count}
###########################################################
proc apply_rules {content rules use_regex use_nocase} {
    # Build command alias table so OPT/VAL rules match either the original
    # or the renamed command name (chain-rename support). A command that
    # was renamed by a CMD rule becomes interchangeable with its new name.
    set alias_map [build_cmd_aliases ${rules}]

    set changed 0
    foreach rule ${rules} {
        set type [lindex ${rule} 0]
        set rest [lrange ${rule} 1 end]
        set r_regexp ${use_regex}
        set r_nocase ${use_nocase}
        set args {}
        foreach a ${rest} {
            if {${a} eq "-regexp"} {
                set r_regexp 1
                continue
            }
            if {${a} eq "-nocase"} {
                set r_nocase 1
                continue
            }
            lappend args ${a}
        }
        # OPT/VAL rules carry the command name as their first field. Expand
        # it to the full alias list so both the original and renamed command
        # are matched (e.g. {CMD AA BB} lets {OPT AA ...} or {OPT BB ...} work).
        if {${type} eq "OPT" || ${type} eq "VAL"} {
            set _cmd_field [lindex ${args} 0]
            if {[dict exists ${alias_map} ${_cmd_field}]} {
                set _aliases [dict get ${alias_map} ${_cmd_field}]
            } else {
                set _aliases [list ${_cmd_field}]
            }
            set args [lreplace ${args} 0 0 ${_aliases}]
        }
        set before ${content}
        set content [apply_one_rule ${content} ${type} ${r_regexp} ${r_nocase} {*}${args}]
        if {${content} ne ${before}} {
            incr changed
        }
    }
    return [list ${content} ${changed}]
}

###########################################################
# proc modify_plain_file
# Desc: in-place modify a plain text file (e.g. .tcl), binary safe.
###########################################################
proc modify_plain_file {filepath rules use_regex use_nocase} {
    if {![file readable ${filepath}] || ![file writable ${filepath}]} {
        __GENERIC_PROCS__::__report_message__ "File ${filepath} read/write permission denied" -severity warn
        return 0
    }
    if {[catch {
        set fd [open ${filepath} r]
        fconfigure ${fd} -translation binary -encoding binary
        set content [read ${fd}]
        close ${fd}
    } err]} {
        __GENERIC_PROCS__::__report_message__ "Read ${filepath} failed: ${err}" -severity error
        return 0
    }

    lassign [apply_rules ${content} ${rules} ${use_regex} ${use_nocase}] new_content changed
    if {!${changed}} {
        return 0
    }

    if {[catch {
        set fd [open ${filepath} w]
        fconfigure ${fd} -translation binary -encoding binary
        puts -nonewline ${fd} ${new_content}
        close ${fd}
    } err]} {
        __GENERIC_PROCS__::__report_message__ "Write ${filepath} failed: ${err}" -severity error
        return 0
    }
    return 1
}

###########################################################
# proc archive_member_allowed
# Desc: decide whether an archive member should be modified,
#       based on -archive_suffix_list (default: .tcl).
#       An empty list means "modify every regular-file member".
###########################################################
proc archive_member_allowed {mem archive_suffix_list} {
    if {[llength ${archive_suffix_list}] == 0} {
        return 1
    }
    foreach suf ${archive_suffix_list} {
        if {[string match "*${suf}" ${mem}]} {
            return 1
        }
    }
    return 0
}

###########################################################
# proc modify_tar_archive
# Desc: in-place modify selected members inside a .tar.gz / .tgz archive.
#       The archive itself is rewritten; other members are preserved.
#       Only members matching -archive_suffix_list (default: .tcl) are touched.
###########################################################
proc modify_tar_archive {filepath rules use_regex use_nocase archive_suffix_list} {
    if {![file readable ${filepath}] || ![file writable ${filepath}]} {
        __GENERIC_PROCS__::__report_message__ "File ${filepath} read/write permission denied" -severity warn
        return 0
    }

    # Create a temporary file for the intermediate .tar.
    # [file tempfile] is unavailable in some Tcl 8.6 builds; fall back to
    # constructing the path manually from the system TEMP directory.
    if {[catch {set tmp_tar [file tempfile]}]} {
        set _tmpdir ""
        foreach _v {TEMP TMP} {
            if {[info exists ::env(${_v})] && $::env(${_v}) ne ""} {
                set _tmpdir $::env(${_v})
                break
            }
        }
        if {${_tmpdir} eq ""} { set _tmpdir "." }
        set tmp_base [file normalize [file join ${_tmpdir} "rebuild_regcase_[pid]_[clock milliseconds].tar"]]
        set tmp_tar [open ${tmp_base} w]
        close ${tmp_tar}
        set tmp_tar ${tmp_base}
    } else {
        close ${tmp_tar}
    }
    unset -nocomplain _tmpdir _v

    if {[catch {exec gzip -dc ${filepath} > ${tmp_tar}} err]} {
        __GENERIC_PROCS__::__report_message__ "Decompress ${filepath} failed: ${err}" -severity error
        file delete -force ${tmp_tar}
        return 0
    }

    set member_list [list]
    if {[catch {set member_list [split [exec tar -tf ${tmp_tar}] "\n"]} err]} {
        __GENERIC_PROCS__::__report_message__ "List members of ${filepath} failed: ${err}" -severity error
        file delete -force ${tmp_tar}
        return 0
    }

    # Transient staging dir (deleted after use). Only members matching
    # -archive_suffix_list (default: .tcl) are modified; the rest are preserved.
    # Create a temporary staging directory.
    # [file tempdir] is unavailable in some Tcl 8.6 builds; fall back to
    # constructing the path manually from the system TEMP directory.
    if {[catch {set temp_dir [file tempdir]}]} {
        set _tmpdir ""
        foreach _v {TEMP TMP} {
            if {[info exists ::env(${_v})] && $::env(${_v}) ne ""} {
                set _tmpdir $::env(${_v})
                break
            }
        }
        if {${_tmpdir} eq ""} { set _tmpdir "." }
        set temp_dir [file normalize [file join ${_tmpdir} "rebuild_regcase_staging_[pid]_[clock milliseconds]"]]
        file mkdir ${temp_dir}
    }
    unset -nocomplain _tmpdir _v
    set changed 0
    # GNU tar prints "Removing leading '/' from member names" to stderr and
    # returns a non-zero exit code when members are stored with absolute
    # paths -- even though the extraction itself SUCCEEDS (it places the
    # files relative to -C). Redirect stderr to the null device so this
    # benign warning is not mistaken for a failure.
    set _null [expr {${::tcl_platform(platform)} eq "windows" ? "NUL" : "/dev/null"}]

    # Extract EVERY member at once into the staging dir. GNU tar strips the
    # leading '/' from absolute member names automatically, placing files
    # relative to -C. Extracting everything (not only target types) guarantees
    # non-target members are preserved when the archive is rebuilt.
    if {[catch {exec tar -xf ${tmp_tar} -C ${temp_dir} 2>${_null}} err]} {
        __GENERIC_PROCS__::__report_message__ "Extract members of ${filepath} warning: ${err}" -severity warn
    }
    unset -nocomplain _null

    foreach mem ${member_list} {
        set mem [string trim ${mem}]
        if {${mem} eq ""} {
            continue
        }
        # Strip leading '/' so the member name becomes a relative path.
        # Some archives store members with absolute paths; keeping the '/'
        # would cause tar to ignore -C or emit warnings when repacking.
        set rel_mem [string trimleft ${mem} "/"]
        if {${rel_mem} eq ""} {
            continue
        }
        set mem_path [file join ${temp_dir} ${rel_mem}]
        # Only members matching -archive_suffix_list are modified in place;
        # everything else is kept verbatim.
        if {[file isfile ${mem_path}] && [archive_member_allowed ${rel_mem} ${archive_suffix_list}]} {
            if {[modify_plain_file ${mem_path} ${rules} ${use_regex} ${use_nocase}]} {
                set changed 1
                __GENERIC_PROCS__::__report_message__ "Modified inside archive ${filepath} : ${rel_mem}" -severity info
            }
        }
    }

    if {${changed}} {
        file delete -force ${tmp_tar}
        # Repack the archive from the ORIGINAL member names (leading '/' stripped),
        # keeping every member that still exists in the staging dir. This preserves
        # ALL members -- both modified (.tcl) and untouched (non-.tcl) ones -- so no
        # data is lost. Leading '/' has been stripped, so GNU tar will NOT emit the
        # "Removing leading '/'" warning that previously caused the rebuild to fail.
        set repack_list [list]
        foreach mem ${member_list} {
            set rel_mem [string trimleft [string trim ${mem}] "/"]
            if {${rel_mem} eq ""} {
                continue
            }
            if {[file exists [file join ${temp_dir} ${rel_mem}]]} {
                lappend repack_list ${rel_mem}
            }
        }
        if {[catch {
            exec tar -cf ${tmp_tar} -C ${temp_dir} {*}${repack_list}
            file delete -force ${filepath}
            exec gzip -c ${tmp_tar} > ${filepath}
        } err]} {
            __GENERIC_PROCS__::__report_message__ "Rebuild archive ${filepath} failed: ${err}" -severity error
            file delete -force ${tmp_tar}
            file delete -force ${temp_dir}
            return 0
        }
    }

    file delete -force ${tmp_tar}
    file delete -force ${temp_dir}
    return ${changed}
}

###########################################################
# proc file_worker
# Desc: dispatch one file to the proper modifier by extension.
#       Returns: {filepath changed_flag}
###########################################################
proc file_worker {file_item rules use_regex use_nocase archive_suffix_list} {
    set f ${file_item}
    if {[string match "*.tcl" ${f}]} {
        set ret [modify_plain_file ${f} ${rules} ${use_regex} ${use_nocase}]
    } elseif {[string match "*.tar.gz" ${f}] || [string match "*.tgz" ${f}]} {
        set ret [modify_tar_archive ${f} ${rules} ${use_regex} ${use_nocase} ${archive_suffix_list}]
    } else {
        __GENERIC_PROCS__::__report_message__ "Skip unsupported file type: ${f}" -severity warn
        set ret 0
    }
    return [list ${f} ${ret}]
}

###########################################################
# proc run_single_thread
###########################################################
proc run_single_thread {file_list rules use_regex use_nocase archive_suffix_list} {
    set result_list [list]
    foreach f ${file_list} {
        lappend result_list [file_worker ${f} ${rules} ${use_regex} ${use_nocase} ${archive_suffix_list}]
    }
    return ${result_list}
}

###########################################################
# proc run_multi_thread
# Desc: use the Tcl Thread package (tpool) for parallel processing.
#       Falls back to single-thread if Thread is unavailable.
###########################################################
proc run_multi_thread {file_list rules use_regex use_nocase thread_num archive_suffix_list} {
    # --- Robust multi-thread with graceful degradation ---
    # A large 7000+ file run must NEVER be aborted by a missing or partial
    # Thread/tpool installation.  Any failure in loading the Thread package or
    # in ANY tpool sub-command (create / presend / post / wait / release)
    # falls back to single-thread processing.  This covers the observed
    # "invalid command name *tpool::presend" crash where the Thread package
    # loads but its tpool ensemble is absent or inconsistent.
    if {[catch {package require Thread} err]} {
        __GENERIC_PROCS__::__report_message__ "Thread package not available (${err}), fallback to single thread" -severity warn
        return [run_single_thread ${file_list} ${rules} ${use_regex} ${use_nocase} ${archive_suffix_list}]
    }

    set pool ""
    set results ""
    set code [catch {
        set pool [tpool::create -minworkers ${thread_num} -maxworkers ${thread_num}]
        # Each worker sources this script so all helper procs become available.
        tpool::presend ${pool} [list source ${::rebuild_script_path}]

        set job_ids [list]
        foreach f ${file_list} {
            lappend job_ids [tpool::post ${pool} [list file_worker ${f} ${rules} ${use_regex} ${use_nocase} ${archive_suffix_list}]]
        }

        set results [tpool::wait ${pool} ${job_ids}]
        tpool::release ${pool}
        set pool ""
    } err opt]

    if {${code} != 0} {
        # Best-effort cleanup of a partially created pool before giving up.
        if {${pool} ne ""} {
            catch {tpool::release ${pool}}
            set pool ""
        }
        __GENERIC_PROCS__::__report_message__ "Multi-thread pipeline failed (${err}), fallback to single thread" -severity warn
        return [run_single_thread ${file_list} ${rules} ${use_regex} ${use_nocase} ${archive_suffix_list}]
    }

    set out [list]
    dict for {jid res} ${results} {
        lappend out ${res}
    }
    return ${out}
}

###########################################################
# proc resolve_case_files
# Desc: resolve -case / -case_list / -case_dir into a unique file list.
###########################################################
proc resolve_case_files {opt_dict} {
    array set opts ${opt_dict}
    set file_list [list]
    set source_count 0

    if {[info exists opts(-case)] && ${opts(-case)} ne ""} {
        incr source_count
        lappend file_list ${opts(-case)}
    }

    if {[info exists opts(-case_list)] && ${opts(-case_list)} ne ""} {
        incr source_count
        set clist ${opts(-case_list)}
        if {![file exists ${clist}]} {
            __GENERIC_PROCS__::__report_message__ "case_list file ${clist} not found" -severity error
            return -code error "case_list not exist"
        }
        set fh [open ${clist} r]
        set content [read ${fh}]
        close ${fh}
        foreach line [split ${content} "\n"] {
            set line [string trim ${line}]
            if {${line} ne "" && ![string match "#*" ${line}]} {
                lappend file_list ${line}
            }
        }
    }

    if {[info exists opts(-case_dir)] && ${opts(-case_dir)} ne ""} {
        incr source_count
        set dir_files [find_files ${opts(-case_dir)} \
            -suffix_list ${opts(-suffix_list)} \
            -include_str ${opts(-include_str)} \
            -logic ${opts(-logic)}]
        set file_list [concat ${file_list} ${dir_files}]
    }

    if {${source_count} == 0} {
        USAGE
        return -code error "Must specify at least one of -case / -case_list / -case_dir"
    }

    return [lsort -unique ${file_list}]
}

###########################################################
# proc load_rules_file
# Desc: read a rule file (Tcl list of rules). Tolerant of either a single
#       outer list or one rule per line.
###########################################################
proc load_rules_file {path} {
    set fh [open ${path} r]
    set raw [read ${fh}]
    close ${fh}

    # A rule file is a Tcl LIST of rules. Valid forms:
    #   (A) flat, no wrapper        : CMD/OPT/VAL rules separated by spaces
    #   (B) single rule, no wrapper : one rule enclosed in braces
    #   (C) wrapped in one extra pair of braces for readability (multi-line)
    # Tcl parses form (C)'s outer wrapper as a SINGLE braced word, collapsing
    # every rule into one element. We peel the outermost brace pair ONLY when
    # the wrapper actually holds a *list* of rules -- i.e. the first
    # non-whitespace char after the opening brace is another opening brace.
    # A single bare rule (form B) must NOT be peeled, otherwise its one brace
    # pair is stripped and the rule's fields get flattened into separate rules.
    set trimmed [string trim ${raw}]
    if {[string index ${trimmed} 0] eq "\{"} {
        set len [string length ${trimmed}]
        set j 1
        while {${j} < ${len} && [string is space [string index ${trimmed} ${j}]]} {
            incr j
        }
        if {${j} < ${len} && [string index ${trimmed} ${j}] eq "\{"} {
            set depth 0
            set match_end -1
            for {set i 0} {${i} < ${len}} {incr i} {
                set ch [string index ${trimmed} ${i}]
                if {${ch} eq "\{"} {
                    incr depth
                } elseif {${ch} eq "\}"} {
                    incr depth -1
                    if {${depth} == 0} {
                        set match_end ${i}
                        break
                    }
                }
            }
            if {${match_end} == [expr {${len} - 1}]} {
                set trimmed [string range ${trimmed} 1 end-1]
            }
        }
    }

    # Parse the (possibly peeled) content as a Tcl list of rules. We use
    # [lrange $trimmed 0 end] which parses the string as a list WITHOUT
    # evaluating its elements -- never [eval], which would try to execute
    # CMD/OPT/etc. as commands.
    set rules [list]
    if {![catch {set rules [lrange ${trimmed} 0 end]}] && [llength ${rules}] > 0} {
        return ${rules}
    }

    # Fallback: one rule per non-comment line (each line is itself a rule list).
    set rules [list]
    foreach line [split ${raw} "\n"] {
        set line [string trim ${line}]
        if {${line} eq "" || [string match "#*" ${line}]} {
            continue
        }
        if {![catch {set r [lrange ${line} 0 end]}]} {
            lappend rules ${r}
        }
    }
    return ${rules}
}

###########################################################
# proc main
###########################################################
proc main {} {
    # Debug: set environment variable DEBUG_PARSE=1 to trace argument parsing
    if {[info exists ::env(DEBUG_PARSE)] && ${::env(DEBUG_PARSE)}} {
        puts "DEBUG: \$::argv = {${::argv}}"
        puts "DEBUG: llength = [llength ${::argv}]"
        for {set _di_ 0} {${_di_} < [llength ${::argv}]} {incr _di_} {
            puts "DEBUG:   argv\[${_di_}\] = [lindex ${::argv} ${_di_}]"
        }
    }

    set defArgDict [dict create]
    set defKeyDict [dict create -help false -regexp false -nocase false]
    set defKeyValDict [dict create \
        -case "" -case_list "" -case_dir "" \
        -find "" -replace "" -rule_file "" \
        -cmd "" -opt "" -val "" \
        -suffix_list {.tcl .tar.gz .tgz} -include_str {} -logic "and" \
        -archive_suffix_list {.tcl} -thread 1]

    if {[catch {
        __GENERIC_PROCS__::__optParse__ ${defArgDict} ${defKeyDict} ${defKeyValDict} USAGE ${::argv}
    } err]} {
        __GENERIC_PROCS__::__report_message__ "Parse argument error: ${err}" -severity error
        USAGE
        exit 1
    }

    # Debug: show parsed values
    if {[info exists ::env(DEBUG_PARSE)] && ${::env(DEBUG_PARSE)}} {
        puts "DEBUG: after optParse:"
        foreach _v_ {-find -replace -rule_file -case -case_list -case_dir -cmd -opt -val -suffix_list -thread} {
            if {[info exists ${_v_}]} {
                puts "DEBUG:   ${_v_} = [set ${_v_}]"
            } else {
                puts "DEBUG:   ${_v_} = <UNSET>"
            }
        }
    }

    if {[info exists -help] && ${-help}} {
        USAGE
        exit 0
    }

    if {${-case} eq "" && ${-case_list} eq "" && ${-case_dir} eq ""} {
        __GENERIC_PROCS__::__report_message__ "Must specify at least one of -case / -case_list / -case_dir" -severity error
        USAGE
        exit 1
    }

    # Build the replacement rule set.
    set rules [list]
    if {${-rule_file} ne ""} {
        if {![file exists ${-rule_file}]} {
            __GENERIC_PROCS__::__report_message__ "Rule file ${-rule_file} not found" -severity error
            exit 1
        }
        set rules [load_rules_file ${-rule_file}]
    }
    if {${-find} ne "" && ${-replace} ne ""} {
        lappend rules [list KW ${-find} ${-replace}]
    }

    # Command-line shortcuts for CMD / OPT / VAL.
    # Each option takes ONE braced Tcl list value (consistent with
    # -suffix_list). Arity is validated before the rule is built.
    # An accidental type-prefix (CMD/OPT/VAL/KW) as the first element is
    # auto-stripped so that both "-cmd {old new}" and "-cmd {CMD old new}"
    # are accepted.
    # NOTE: we cannot "set -cmd ..." because Tcl treats leading "-" in
    # [set] as a flag.  Use a temporary variable (_cv) instead.
    if {${-cmd} ne ""} {
        set _cv ${-cmd}
        if {[lsearch -exact {CMD OPT VAL KW} [lindex ${_cv} 0]] >= 0} {
            set _cv [lrange ${_cv} 1 end]
        }
        if {[llength ${_cv}] != 2} {
            __GENERIC_PROCS__::__report_message__ "-cmd expects {old_cmd new_cmd}, got [llength ${_cv}] elements: {${_cv}}" -severity error
            exit 1
        }
        lappend rules [linsert ${_cv} 0 CMD]
    }
    if {${-opt} ne ""} {
        set _cv ${-opt}
        if {[lsearch -exact {CMD OPT VAL KW} [lindex ${_cv} 0]] >= 0} {
            set _cv [lrange ${_cv} 1 end]
        }
        if {[llength ${_cv}] != 3} {
            __GENERIC_PROCS__::__report_message__ "-opt expects {cmd old_opt new_opt}, got [llength ${_cv}] elements: {${_cv}}" -severity error
            exit 1
        }
        lappend rules [linsert ${_cv} 0 OPT]
    }
    if {${-val} ne ""} {
        set _cv ${-val}
        if {[lsearch -exact {CMD OPT VAL KW} [lindex ${_cv} 0]] >= 0} {
            set _cv [lrange ${_cv} 1 end]
        }
        set n [llength ${_cv}]
        if {${n} != 3 && ${n} != 4} {
            __GENERIC_PROCS__::__report_message__ "-val expects {cmd old_val new_val} or {cmd opt old_val new_val}, got ${n} elements: {${_cv}}" -severity error
            exit 1
        }
        lappend rules [linsert ${_cv} 0 VAL]
    }

    if {[llength ${rules}] == 0} {
        __GENERIC_PROCS__::__report_message__ "Must provide -find/-replace or -rule_file" -severity error
        USAGE
        exit 1
    }

    set use_regex ${-regexp}
    set use_nocase ${-nocase}

    if {![string is integer ${-thread}] || ${-thread} < 1} {
        __GENERIC_PROCS__::__report_message__ "-thread must be a positive integer" -severity error
        exit 1
    }

    set opt_dict [dict create \
        -case ${-case} -case_list ${-case_list} -case_dir ${-case_dir} \
        -suffix_list ${-suffix_list} -include_str ${-include_str} -logic ${-logic}]

    if {[catch {set case_file_list [resolve_case_files ${opt_dict}]} err]} {
        __GENERIC_PROCS__::__report_message__ "Resolve input case failed: ${err}" -severity error
        exit 1
    }

    __GENERIC_PROCS__::__report_message__ "Total target case files: [llength ${case_file_list}]" -severity info
    __GENERIC_PROCS__::__report_message__ "Rules: [llength ${rules}], regexp:${use_regex}, nocase:${use_nocase}, thread:${-thread}" -severity info

    if {${-thread} > 1} {
        set result_list [run_multi_thread ${case_file_list} ${rules} ${use_regex} ${use_nocase} ${-thread} ${-archive_suffix_list}]
    } else {
        set result_list [run_single_thread ${case_file_list} ${rules} ${use_regex} ${use_nocase} ${-archive_suffix_list}]
    }

    set modified_cnt 0
    foreach item ${result_list} {
        lassign ${item} fname changed
        if {${changed}} {
            incr modified_cnt
            __GENERIC_PROCS__::__report_message__ "Modified: ${fname}" -severity info
        }
    }
    __GENERIC_PROCS__::__report_message__ "Finish. Modified file count: ${modified_cnt} / [llength ${case_file_list}]" -severity info
}

###########################################################
# Run main only when executed directly (not when sourced by a worker).
###########################################################
if {[info exists argv0] && [file exists ${argv0}] \
        && [file normalize ${argv0}] eq [file normalize [info script]]} {
    main
}
