#!/bin/sh

install_dir=/alidata/www/test2/node/51fetch_all

ps -ef | grep index.coffee | awk '{print $2}' | xargs kill -9
ps -ef | grep ipproxy_server.coffee | awk '{print $2}' | xargs kill -9

rm -rf logs/*

local_ip=$(ifconfig eth1 | grep inet | cut -d':' -f 2 | cut -d ' ' -f1)

if [ "$local_ip"x = "121.41.173.223"x ]; then
    sleep 5
    forever start --minUptime 60000 --spinSleepTime 60000 -l $install_dir/logs/ipproxy.forever.log -e $install_dir/logs/ipproxy.err.log -o $install_dir/logs/ipproxy.out.log -c coffee src/ipproxy_server.coffee
fi
# forever 让nodejs应用后台执行  start 开始运行
# –minUptime: 最小spin更新时间(ms)
# –spinSleepTime: 两次spin间隔时间
# -l $install_dir/logs/index.forever.log: 输出日志到index.forever.log
# -o $install_dir/logs/index.out.log: 输出控制台信息到index.out.log
# -e $install_dir/logs/index.err.log: 输出控制台错误在index.err.log
# -c coffee, COMMAND: 执行命令，默认是node,这类是coffee
# ecmall51_2  第一个参数 使用数据库 ecmall51_2
# "$local_ip" 第二个参数 当前IP地址
# false       第三个参数 ？？
# api         第四个参数 使用API 获取商品信息
forever start --minUptime 60000 --spinSleepTime 60000 -l $install_dir/logs/index.forever.log -e $install_dir/logs/index.err.log -o $install_dir/logs/index.out.log -c coffee index.coffee ecmall51_2 "$local_ip" false api
