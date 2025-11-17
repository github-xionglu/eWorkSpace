#!/bin/sh

cd D:/lxiong.ENNOCAD/Desktop/我的文档/PV测试/work_summary/
date=$(date +'%Y%m%d')
if git status | grep -q "enno_work_summary"; then
    git add "enno_work_summary"
    git commit -m "work summary ${date}"
fi

