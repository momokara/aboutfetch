http = require 'http'
{parse} = require 'url'
{log, error} = require './util'
config = require './config'

port = 30003
# 代理执行 
# @parama vendor   随机数
# @parama callback 回调方法
getIPProxiesViaApi = (vendor, callback) ->
  http.get config[vendor], (res) ->
    if res.statusCode isnt 200
      res.resume()
      callback new Error('fail to get new ip via api')
      return
    res.setEncoding 'utf8'
    rawJSON = ''
    res.on 'data', (chunk) -> rawJSON += chunk
    res.on 'end', ->
      log "get: #{rawJSON}"
      callback null, rawJSON
  .on 'error', (e) ->
    error "fail to get new ip via api, error: #{e.message}"
    callback e, null


server = http.createServer (req, res) ->
  urlObj = parse req.url, true
  vendor = urlObj.pathname.substr(1)
  getIPProxiesViaApi vendor, (err, json) ->
    if err
      res.writeHead 500
    else
      res.writeHead 200,
        'Content-Length': json.length
        'Content-Type': "text/json;charset=utf-8"
      res.write json
    res.end()

server.on 'clientError', (err, socket) ->
  error "Bad request: #{err}"
server.listen port

log "server is listening: #{port}"
