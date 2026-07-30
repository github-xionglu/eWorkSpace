日期：2026年1月27日

get_cpu_perf：另一个工具支持调查

验证issue：
    #16709 report_runtime without violation information

新进AE issue调查情况
    #50427：在set_param upf.implicit_well_connection true时，对未连接的NWell，PWell报SNetHasNoDriver
    #50533：control信号穿过带常值的选择器连接到iso的en pin，工具报iso的strategic 失效
    #50531：check_misc卡住
    #50266：成功执行后，修改upf文件，再Project的Read_design阶段reset，再点击run时出现crash，AE使用bsub操作，内部无bsub操作导致无法复现
    
2026年2月2日
    get_cpu_perf基本功能检查回归，lpc，dft，txm，cdc，lint，pipeline卡住kill -60导致jenkins机器上case被kill。


2026年2月25日
    GPA F1 issue 50739: 客户处确认用例原因并创建小case

2026年3月17日
    验证4个bug：
        #51618
        #51626
        #51676
        #51831
    reopen 1 bug：
        #51796
        #50665: color of check_upf on the Project tab
        