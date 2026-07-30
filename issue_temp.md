[ELPC][IsoClampValueConflictWithState] IsoClampValueConflictWithState is missing reported with the clock pin of the 2-pin retention
[MFP][FPBlackBoxBlockMainPath][set_timing_false_path] FPBlackBoxBlockMainPath is missing reported with multi-input and multi-output bbox

## Description

When `set_timing_false_path` is set on the multi-input and multi-output __bbox__ through `-through`, FPBlackBoxBlockMainPath is missing report and the tool does not report any error

## Step

1. start mfp tool

2. read the design file

3. read the sdc file

4. exec check_false_path
`check_false_path`

### ==>

## Result

1. there is not any message reported

## Expect

1. the FPBlackBoxBlockMainPath is reported

## Remark

## Test case

===========================

for i in $(ls *high*); do mv $i ${i%%-high-*}-posedge-${i##*-high-}; done
for i in $(ls *posedge*); do mv $i ${i%%-posedge-*}-high-${i##*-posedge-}; done
for i in $(ls *negedge*); do mv $i ${i%%-negedge-*}-low-${i##*-negedge-}; done

for i in $(ls *clock*); do mv $i ${i%%-clock-*}-en-${i##*-clock-}; done
for i in $(ls *ff*); do mv $i ${i%%-ff-*}-latch-${i##*-ff-}; done
sed -i 's/-ff-/-latch-/g' *tcl

sed -i 's/-clock-/-en-/g' *tcl
sed -i 's/-posedge-/-high-/g; s/-negedge-/-low-/g'*tcl

sed -i 's/CKN/G/g; s/CK/G/g; s/RN/R/g; s/SN/S/g' *v
sed -i 's/, QN()//g'*v

sed -i 's/G(net1)/G(en)/g; s/R(reset)/R(net1)/g; s/input reset/input en/g' *v



config_message Lib* -max_occurrence 1

read_library /mnt/efs/fs1/reg_test_data/two_counter/libs/reg_v12.lib -add_pg_pin

report_violation

read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-001.v

catch {read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-002.v }

catch {remove_upf}; catch {remove_design}; catch {remove_lef}; catch {remove_library}

config_message Lib* -max_occurrence 1
read_library /mnt/efs/fs1/reg_test_data/two_counter/libs/reg_v12.lib -add_pg_pin
read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-001.v
remove_design
catch {read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-002.v }
report_violation
config_message -reset
catch {remove_upf}; catch {remove_design}; catch {remove_lef}; catch {remove_library}
config_message Lib* -max_occurrence 1
read_library /mnt/efs/fs1/reg_test_data/two_counter/libs/reg_v12.lib -add_pg_pin
report_violation
read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-001.v
remove_design
catch {read_design /mnt/efs/fs1/reg_test_data/issue_data/9030/8411-stratisolshunnecessary-002.v }
report_violation

list_stashed_design
report_violation -message_id LibSCMRNwellAssumed
remove_upf
remove_design
remove_lef
remove_library

set regBaseDir "/mnt/efs/fs1/reg_test_data/"

read_library /mnt/efs/fs1/reg_test_data/two_counter/libs/lp_v12_ext12.lib
read_design /mnt/efs/fs1/reg_test_data/two_counter/rtl.v
read_design /mnt/efs/fs1/reg_test_data/two_counter/rtl2.v
stash_design top_stash
stash_design two_counter_stash

current_stage

remove_stashed_design top_stash


get_cells {{get_cells get_instances} {-regexp ignore_without_arg} {-nocase ignore_without_arg}  {-of_objects ignore_without_arg} {-hierarchical -transitive} {-quiet ignore_without_arg}}
cmd { {cmd cmdmap} {opt optmap} }

{all_outputs  {get_ports * -filter @dir=="out"}} {-level_sensitive ignore_without_arg}   {-edge_triggered ignore_without_arg} {-clock ignore_with_arg}
cmd map         == {all_outputs  {get_ports * -filter @dir=="out"}}
cmd map cmd     == all_outputs
cmd map map     == {get_ports * -filter @dir=="out"}
opt map dict    == {-level_sensitive ignore_without_arg -edge_triggered ignore_without_arg -clock ignore_with_arg}


The false path statement set between two flip-flops, for example: 
set_false_path -from [get_cells ff1] -to [get_cells ff2] 

Regarding the handling of set_disable_timing set on different timing arcs, PT's processing approach is summarized as follows: 

Set on the D pin of the starting flip-flop: 
set_disable_timing [get_pins ff1/D] 
This does not affect the verification of the false path. 

Set on the CK pin of the starting flip-flop: 
set_disable_timing [get_pins ff1/CK] 
It is treated as No Path Found. 

Set on the Q pin of the starting flip-flop: 
set_disable_timing [get_pins ff1/Q] 
It is treated as No Path Found. 

Set on the timing arc from the CK pin to the D pin of the destination flip-flop: 
set_disable_timing -from CK -to D [get_cells ff2] 
It is treated as No Path Found. 

Set on the CK pin of the destination flip-flop: 
set_disable_timing [get_pins ff2/CK] 
It is treated as No Path Found. 

Set on the Q pin of the destination flip-flop: 
set_disable_timing [get_pins ff2/Q] 
This does not affect the verification of the false path. 

Set on the D pin of the destination flip-flop: 
set_disable_timing [get_pins ff2/D] 
This does not affect the verification of the false path. 

Set on the timing arc from the CK pin to the D pin of the starting flip-flop: 
set_disable_timing –from CK –to D [get_cells ff1] 
It is treated as No Path Found. 