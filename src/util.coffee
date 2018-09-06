{log, inspect} = require 'util'
# 输入日志
exports.log = log
# 输出错误
exports.error = (err) ->
  console.error err
  console.error 'stack info: ' + err.stack
# 输出debug 如何环境参数为 'debug' 时
exports.debug = (msg) ->
  if process.env.NODE_ENV is 'debug' or process.env.NODE_ENV is 'trace'
    console.log msg
# 输出debug 如何环境参数为 'trace' 时
exports.trace = (msg) ->
  if process.env.NODE_ENV is 'trace'
    console.log '**********trace output start**********'
    console.log msg
    console.log '**********trace output end**********'
# 监听调试
exports.inspect = inspect
# 获取货号
exports.getHuoHao = (title) ->
  regex = /[A-Z]?#?(\d+[A-Z]?)#?/g
  matches = regex.exec title
  if matches? and ~matches[0].indexOf('#')
    matches[1]
  else
    while matches? and ((matches[1].length is 4 and matches[1].substr(0, 3) is '201') or matches[1].length is 1 or (matches[1].length is 2 and ~['16','17','18','19'].indexOf(matches[1]))) # no problem before 2019 inclusive
      matches = regex.exec title
    matches?[1] || ''

exports.removeNumbersAndSymbols = (text) ->
  text.replace /[\d# /]/g, ''
