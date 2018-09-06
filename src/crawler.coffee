Q = require 'q'
jquery = require('jquery')
{log, error, inspect, debug, trace, removeNumbersAndSymbols} = require './util'
{fetch, makeJsDom, setRateLimits} = require './crawler'
database = require './database'

db = new database()

query = Q.nbind db.query, db
saveItems = Q.nbind db.saveItems, db
deleteDelistItems = Q.nbind db.deleteDelistItems, db
# 爬取店铺
# @parama    店铺信息
# @fullCrawl --未知
# @done      回调方法
exports.crawlStore = (store, fullCrawl, done) ->
  items = []
  crawlNextPage "#{store['resweb_http']}?&currentPage=1", items, store
    .then ->
      query "select goods_name, default_image, price, taobao_price, good_http from ecm_goods where store_id = #{store['store_id']}"
    .then (goods) ->
      mergeItems goods, items
      crawlExtraItemInfo items, 0
    .then ->
      saveItems store['store_id'], store['store_name'], items, '', '所有宝贝', 1
    .then ->
      deleteDelistItems store['store_id'], store['total_items_count']
    .then ->
      done()
    .catch (err) ->
      error err
      done()

crawlNextPage = (url, items, store) ->
  fetch url, 'GET'
    .then (res) ->
      body = res.body
      makeJsDom body
    .then (window) ->
      $ = jquery window
      setTotalCount store, $
      pushItems items, $
      nextUrl = nextPage $, url
      if nextUrl
        window.close()
        log "store #{store['store_id']} crawled one page, ready for the next page"
        crawlNextPage nextUrl, items, store
      else
        window.close()
    .catch (err) ->
      error url
      error err
      throw err

mergeItems = (goods, items) ->
  for item in items
    for good in goods
      if removeNumbersAndSymbols(item.goodsName) is removeNumbersAndSymbols(good['goods_name']) and item.defaultImage is good['default_image'] and parseInt(item.price) is parseInt(good['price'])
        item.taobaoPrice = good['taobao_price']
        item.goodHttp = good['good_http']
        item.fetched = true

crawlExtraItemInfo = (items, index) ->
  if items[index].fetched
    log "#{items[index].goodsName} already fetched before so skip"
    if index + 1 < items.length
      crawlExtraItemInfo items, index + 1
    else
      true
  else
    fetch items[index].reswebHttp, 'GET'
      .then (res) ->
        body = res.body
        makeJsDom body
      .then (window) ->
        $ = jquery window
        items[index].goodHttp = goodHttp $
        items[index].taobaoPrice = taobaoPrice $
        items[index].huohao = huohao $
        log items[index]
        window.close()
        if index + 1 < items.length
          crawlExtraItemInfo items, index + 1
      .catch (err) ->
        error items[index].reswebHttp
        error err
        throw err

setTotalCount = (store, $) ->
  count = parseInt $('.nc-count .num').text()
  store['total_items_count'] = count

pushItems = (items, $) ->
  $('#content_all .goods-list .item').each (index, element) ->
    $e = $(element)
    items.push
      goodsName: goodsName $e
      defaultImage: defaultImage $e
      price: price $e
      reswebHttp: reswebHttp $e
      taobaoPrice: ''
      goodHttp: ''

nextPage = ($, currentUrl) ->
  currentPage = parseInt /window.CURRENTPAGE = '(\d+)'/.exec($('body').html())?[1]
  pageCount = parseInt /window.PAGECOUNT = '(\d+)'/.exec($('body').html())?[1]
  if currentPage < pageCount
    currentUrl.replace /currentPage=\d+/, "currentPage=#{currentPage + 1}"
  else
    ''

goodsName = ($) ->
  $.find('.title').text().trim()

defaultImage = ($) ->
  "http:" + $.find('.pic img').attr('data-original').replace(/230x230/, '240x240')

price = ($) ->
  $.find('.fl.price').text().trim().substr(1)

taobaoPrice = ($) ->
  $('.v-price .d-sale').eq(1).text()

reswebHttp = ($) ->
  "http://www.resweb.com#{$.find('.title a').attr('href')}"

goodHttp = ($) ->
  $('.product-detail .d-name a').attr('href').replace('https', 'http')

huohao = ($) ->
  $('.value.ff-arial').eq(0).text().trim().replace(/#/g, '')
