# 加密模块
crypto = require 'crypto'
phpjs = require 'phpjs'
# 提供http服务
http = require 'http'
# 对http请求所带的数据进行解析
querystring = require 'querystring'
# 配置文件
config = require './config'
# 获取淘宝的上架商品列表
exports.getTaobaoItemsOnsaleBatch = (fields, pageNo, session, items, callback) ->
  exports.getTaobaoItemsOnsale fields, pageNo, session, (err, res) ->
    if err
      callback err, null
      return
    if res.items?.item? then items.push res.items.item...
    if items.length < res.total_results
      exports.getTaobaoItemsOnsaleBatch fields, (parseInt(pageNo) + 1) + '', session, items, callback
    else
      callback null, items
# 通过淘宝的接口获取上架商品列表
exports.getTaobaoItemsOnsale = (fields, pageNo, session, callback) ->
  apiParams =
    'fields': fields
    'order_by': 'modified:desc'
    'page_size': '200'
    'page_no': pageNo
  execute 'taobao.items.onsale.get', apiParams, session, (err, result) ->
    if result.items_onsale_get_response?
      callback null, result.items_onsale_get_response
    else
      handleError err, result, callback

exports.getTaobaoItemsSellerListBatch = (numIids, fields, session, items, callback) ->
  numIidsList = numIids.split ','
  if numIidsList.length > 0 and numIidsList[0]
    iids = numIidsList.splice 0, 10
    exports.getTaobaoItemsSellerList iids.join(','), fields, session, (err, itemsList) ->
      if err
        callback err, null
        return
      items.push itemsList...
      exports.getTaobaoItemsSellerListBatch numIidsList.join(','), fields, session, items, callback
  else
    callback null, items

exports.getTaobaoItemsSellerList = (numIids, fields, session, callback) ->
  apiParams =
    'num_iids': numIids
    'fields': fields
  execute 'taobao.items.seller.list.get', apiParams, session, (err, result) ->
    if result.items_seller_list_get_response?.items?.item?
      callback null, result.items_seller_list_get_response.items.item
    else
      handleError err, result, callback
# 获取淘宝销售的商品列表
# 接口参考地址http://open.taobao.com/api.htm?docId=24625&docType=2
exports.getTaobaoItemSeller = (numIid, fields, session, callback) ->
  apiParams =
    'num_iid': numIid
    'fields': fields
  execute 'taobao.item.seller.get', apiParams, session, (err, result) ->
    if result.item_seller_get_response?.item?
      callback null, result.item_seller_get_response.item
    else
      handleError err, result, callback

exports.getTaobaoItem = (numIid, fields, callback) ->
  apiParams =
    'num_iid': numIid
    'fields': fields
  execute 'taobao.item.get', apiParams, null, (err, result) ->
    if result.item_get_response?.item?
      callback null, result.item_get_response.item
    else
      handleError err, result, callback
# 获取商品类目id. CID 
# 接口参考地址 http://open.taobao.com/api.htm?docId=122&docType=2
exports.getItemCats = (cids, fields, callback) ->
  apiParams =
    'cids': "#{cids}"
    'fields': fields
  execute 'taobao.itemcats.get', apiParams, null, (err, result) ->
    if result.itemcats_get_response?.item_cats?.item_cat?
      callback null, result.itemcats_get_response.item_cats.item_cat
    else
      handleError err, result, callback
# 获取前台展示的店铺内卖家自定义商品类目
# 接口参考地址 http://open.taobao.com/api.htm?docId=65&docType=2
exports.getSellercatsList = (nick, callback) ->
  apiParams =
    'nick': nick
  execute 'taobao.sellercats.list.get', apiParams, null, (err, result) ->
    if result.sellercats_list_get_response?
      if result.sellercats_list_get_response?.seller_cats?.seller_cat?
        callback null, result.sellercats_list_get_response.seller_cats.seller_cat
      else
        callback null, []
    else
      handleError err, result, callback
# 获取标准商品类目属性
# 接口参考地址 http://open.taobao.com/api.htm?docId=121&docType=2
exports.getItemProps = (cid, fields, parentPid, callback) ->
  apiParams =
    'cid': cid + ''
    'fields':fields
  if parentPid then apiParams['parent_pid'] = parentPid
  execute 'taobao.itemprops.get', apiParams, null, (err, result) ->
    if result.itemprops_get_response?.item_props?.item_prop?
      callback null, result.itemprops_get_response.item_props.item_prop
    else
      handleError err, result, callback

# execute 发送HTTP 请求访问接口api
# @parma method    接口地址
# @parma apiParams API 接口参数
# @parma session   用户授权登录后的session
# @parma callback   回调方法
execute = (method, apiParams, session, callback) ->
  sysParams =
    'app_key': config.taobao_app_key
    'v': '2.0'
    'format': 'json'
    'sign_method': 'md5'
    'method': method
    'timestamp': phpjs.date 'Y-m-d H:i:s'
    'partner_id': 'top-sdk-php-20140420'
  if session then sysParams['session'] = session
  sign = generateSign phpjs.array_merge sysParams, apiParams
  sysParams['sign'] = sign
  options =
    hostname: 'gw.api.taobao.com'
    path: "/router/rest?#{querystring.stringify sysParams}"
    method: 'POST'
    headers:
      'Content-Type': 'application/x-www-form-urlencoded'
      'Content-Length': querystring.stringify(apiParams).length
  req = http.request options, (res) ->
    chunks = []
    size = 0;
    res.on 'data', (chunk) ->
      chunks.push chunk
      size += chunk.length
    res.on 'end', ->
      data = null
      if size is 0
        data = new Buffer(0)
      else if size is 1
        data = chunks[0]
      else
        data = new Buffer(size)
        pos = 0
        for chunk in chunks
          chunk.copy data, pos
          pos += chunk.length
      res = JSON.parse data.toString()
      callback null, res
  req.on 'error', (err) ->
    callback err, null
  req.write "#{querystring.stringify apiParams}\n"
  req.end()

handleError = (err, result, callback) ->
  if err
    callback err, null
  else
    if result.error_response?
      errorResponse = result.error_response
      callback new Error("#{errorResponse.code}; #{errorResponse.msg}; #{errorResponse.sub_code}; #{errorResponse.sub_msg}"), null
    else
      callback new Error(result), null

generateSign = (params) ->
  sortedParams = ksort params
  str = config.taobao_secret_key
  for k, v of sortedParams
    if v.indexOf('@') isnt 0
      str += "#{k}#{v}"
  str += config.taobao_secret_key
  md5(str).toUpperCase()

ksort = (obj) ->
  phpjs.ksort obj

md5 = (content) ->
  phpjs.md5 content

if process.env.NODE_ENV is 'test'
  exports.generateSign = generateSign
  exports.md5 = md5
  exports.ksort = ksort
  exports.setConfig = (c) -> config = c
