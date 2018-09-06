http = require 'http'
async = require 'async'
{log, error, inspect, debug, trace, getHuoHao} = require './util'
Q = require 'q'
env = require('jsdom').env
jquery = require('jquery')
{fetch} = require './crawler'

database = require './database'
config = require './config'
{getTaobaoItemSeller, getItemCats, getSellercatsList, getItemProps} = require './taobao_api'

TEMPLATES = [
  BY_NEW: ['a.by-new', 'a.cat-name[title="按新品"]']
  CAT_NAME: 'a.cat-name'
  CATS_TREE: 'ul.cats-tree'
  REPLACE: (html, store) ->
    html.replace(/\"\/\/.+category-(\d+)[\w=&\?\.;-].+\"/g, '"showCat.php?cid=$1&shop_id=' + store['store_id'] + '"').replace(/\r\n/g, '')
  ITEM: ['.shop-hesper-bd dl.item', '.tshop-pbsm-shop-item-recommend:eq(0) dl.item']
  ITEM_NAME: ['a.item-name', 'p.title a']
  PRICE: ['.s-price', '.c-price', 'p.price .value']
  CAT_SELECTED: '.hesper-cats ol li:last'
,
  BY_NEW: '#J_Cats a:eq(2)'
  CAT_NAME: 'NON_EXISTS_YET'
  CATS_TREE: 'ul#J_Cats'
  REPLACE: (html, store) ->
    html
  ITEM: '.shop-hesper-bd div.item'
  ITEM_NAME: '.desc a'
  PRICE: '.price strong'
]

CRAWL_ITEM_RETRY_TIMES=5

db = new database()

exports.makeJsDomPromise = makeJsDomPromise = Q.nfbind env

exports.setDatabase = (newDb) ->
  db = newDb

exports.buildOuterIid = (storeId, callback) ->
  db.buildOuterIid storeId, callback

exports.getAllStores = (condition, callback) ->
  db.getStores condition, callback

exports.crawlOneItemInStore = (goodsId, session, done) ->
  crawlItems db.getOneGoodInStore, goodsId, session, done

exports.crawlAllItemsInStore = (storeId, session, done) ->
  crawlItems db.getAllGoodsInStore, storeId, session, done

# 获取店铺中的商品
exports.crawlItemsInStore = (storeId, session, done) ->
  crawlItems db.getUnfetchedGoodsInStore, storeId, session, done

# 爬取商品方法
# @parama getGoodsDbFunc   获取数据库中的列表信息
# @parama storeIdOrGoodsId  商品ID 或者是店铺ID 
# @parama session           缓存中的session
# @parama done              执行后的回调
crawlItems = (getGoodsDbFunc, storeIdOrGoodsId, session, done) ->
  getGoodsDbFunc.call db, storeIdOrGoodsId, (err, goods) ->
    if err
      done new Error('error when call getUnfetchedGoodsInStore on db')
    else
      remainGoods = goods;
      next = ->
        if remainGoods.length > 0
          good = remainGoods.shift()
          exports.crawlItemViaApi good, session, ->
            log "#{good.goods_id}: #{good.goods_name} updated, remain #{remainGoods.length} goods"
            next()
        else
          done()
      next()

# 使用api获取信息
# @parama good  商品信息
# @parama session           缓存中的session
# @parama done              执行后的回调
exports.crawlItemViaApi = (good, session, done) ->
  itemUri = good.good_http
  numIid = getNumIidFromUri itemUri
  callback = (err, item) ->
    if err
      error err
      done()
    else
      # 如果商品状态是 instock 则不爬取 切输出日志
      if item.approve_status is 'instock'
        log "#{good.goods_id}: #{good.goods_name} is instock, no need update"
        return done()
      attrs = parseAttrs item.props_name, item.property_alias
      getHierarchalCats item.cid, (err, cats) ->
        if err or cats.length is 0
          error "getHierarchalCats Error: cid #{item.cid} #{err}"
          done()
        else
          # 更新商品信息
          updateItemDetailInDatabase
            item: item
            good: good
            desc: removeSingleQuotes item.desc
            attrs: attrs
            cats: cats
            realPic: isRealPic item.title, item.props_name
            itemImgs: item.item_imgs?.item_img || []
          , done
  # 如果有session 则去获取淘宝的商品列表
  if session
    getTaobaoItemSeller numIid, 'approve_status,title,seller_cids,desc,pic_url,sku,item_weight,property_alias,price,item_img.url,cid,nick,props_name,prop_img,delist_time', session, callback
  else
    crawlTaobaoItem numIid, callback

exports.crawlStore = (store, fullCrawl, done) ->
  if fullCrawl
    steps = [
      queueStoreUri(store)
      makeJsDom(store)
      updateCateContentAndFetchAllUris(store)
      clearCids(store)
      crawlAllPagesOfByNew(store)
      crawlAllPagesOfAllCates(store)
      deleteDelistItems(store)
    ]
  else
    steps = [
      queueStoreUri(store)
      makeJsDom(store)
      updateCateContentAndFetchAllUris(store)
      crawlAllPagesOfByNew(store)
      deleteDelistItems(store)
    ]
  async.waterfall steps, (err, result) ->
    if err then error err
    done()
# 更新数据库中商品详细信息
updateItemDetailInDatabase = ({item, desc, good, attrs, cats, realPic, itemImgs}, callback) ->
  goodsId = good.goods_id
  itemUri = good.good_http
  title = item.title
  price = good.price
  storeId = good.store_id
  huohao = (getHuoHaoFromAttrs attrs) || (getHuoHao title)
  store = {}
  skus = []
  async.waterfall [
    (callback) ->
      db.getStores "store_id = #{storeId}", (err, stores) ->
        store = stores[0]
        if not store
          callback new Error("goods:#{goodsId} store is undefined")
        else
          callback err, stores
    (result, callback) ->
      skus = parseSkus item.skus, item.property_alias, store['see_price'], title
      price = parsePrice item.price, store['see_price'], title
      db.updateGoods goodsId, title, price, item.price, desc, itemUri, realPic, skus, item.pic_url, item.seller_cids, callback
    (result, callback) ->
      db.updateItemImgs goodsId, itemImgs, callback
    (result, callback) ->
      db.updateCats goodsId, storeId, cats, callback
    (result, callback) ->
      db.updateSpecs skus, goodsId, price, item.price, huohao, callback
    (result, callback) ->
      if result?
        insertId = if result.length > 0 then result[0].insertId else result.insertId
        db.updateDefaultSpec goodsId, insertId, callback
      else
        callback null, null
    (result, callback) ->
      outerId = makeOuterId store, huohao, price
      outerIdAttr =
        attrId: '1'
        valueId: '1'
        attrName: '商家编码'
        attrValue: outerId
      attrs.push outerIdAttr
      db.saveItemAttr goodsId, attrs, callback
  ], (err, result) ->
    if err then error err
    callback null

queueStoreUri = (store) ->
  (callback) ->
    fetchStorePage(makeSureProtocol("#{store['shop_http']}/search.htm?search=y&orderType=newOn_desc&viewType=grid"), 'POST', banned)
      .then (result) ->
        callback null, result
      .catch (err) ->
        callback err, null

makeJsDom = (store) ->
  (result, callback) ->
    if result.body is ''
      callback new Error("id:#{store['store_id']} #{store['store_name']} doesn't exist"), null
    else
      env result.body, callback

updateCateContentAndFetchAllUris = (store) ->
  (window, callback) ->
    $ = jquery window
    catsTreeHtml = removeSingleQuotes extractCatsTreeHtml $, store
    if catsTreeHtml isnt ''
      store['total_items_count'] = parseInt($('.search-result span').text())
      db.updateStoreCateContent store['store_id'], store['store_name'], catsTreeHtml
      imWw = extractImWw $, store['store_id'], store['store_name']
      if imWw then db.updateImWw store['store_id'], store['store_name'], imWw
      uris = extractUris $, store
      window.close()
      callback null, uris
    else
      store['total_items_count'] = 0
      window.close()
      # log "NoCategoryContent: #{store['store_id']} #{store['store_name']} catsTreeHtml is empty"
      # process.exit 97
      callback new Error("NoCategoryContent: #{store['store_id']} #{store['store_name']} catsTreeHtml is empty"), null

extractUris = ($, store) ->
  uris =
    byNewUris: []
    catesUris: []
  for template in TEMPLATES
    BY_NEW = selectRightTemplate $('body'), template.BY_NEW
    if $(BY_NEW).length > 0
      uris.byNewUris.push makeSureProtocol($(BY_NEW).attr('href') + '&viewType=grid')
    $(template.CAT_NAME).each (index, element) ->
      uri = $(element).attr('href')
      if uris.catesUris.indexOf(uri) is -1 and ~uri.indexOf('category-') and (~uri.indexOf('#bd') or ~uri.indexOf('categoryp'))
        uris.catesUris.push makeSureProtocol(uri.replace('#bd', '') + '&viewType=grid')
    if $(BY_NEW).length > 0 then break
  uris

exports.extractImWw = extractImWw = ($, storeId, storeName) ->
  imWw = $('.J_WangWang').attr('data-nick')
  if imWw
    decodeURI imWw
  else
    error "id:#{storeId} #{storeName} cannot find im_ww."
    ''

clearCids = (store) ->
  (uris, callback) ->
    db.clearCids store['store_id'], (err, result) ->
      if err
        callback err, null
      else
        callback null, uris

changeRemains = (store, action, callback, err = null) ->
  if err
    callback err
    return
  if not store.remains? then store.remains = 0
  if action is '+'
    store.remains++
  else if action is '-'
    store.remains--
    if store.remains is 0 then callback err

crawlAllPagesOfByNew = (store) ->
  (uris, callback) ->
    callbackWithUris = (err) ->
      callback err, uris
    if uris.byNewUris.length > 0
      for uri in uris.byNewUris
        changeRemains store, '+', callback
        fetchStorePage(makeSureProtocol(uri), 'POST', banned)
          .then (result) ->
            saveItemsFromPageAndQueueNext(store, callbackWithUris)(null, result)
          .catch (err) ->
            saveItemsFromPageAndQueueNext(store, callbackWithUris)(err, null)
    else
      callback null, uris

crawlAllPagesOfAllCates = (store) ->
  (uris, callback) ->
    callbackWithUris = (err) ->
      callback err, uris
    if uris.catesUris.length > 0
      for uri in uris.catesUris
        changeRemains store, '+', callback
        fetchStorePage(makeSureProtocol(uri), 'POST', banned)
          .then (result) ->
            saveItemsFromPageAndQueueNext(store, callbackWithUris)(null, result)
          .catch (err) ->
            saveItemsFromPageAndQueueNext(store, callbackWithUris)(err, null)
    else
      callback null, uris

deleteDelistItems = (store) ->
  (result, callback) ->
    db.deleteDelistItems store['store_id'], store['total_items_count'], callback

updateCategories = (store) ->
  (uris, callback) ->
    getSellercatsList store['im_ww'], (err, cats) ->
      if cats
        db.updateCategories store['store_id'], cats, (err, result) ->
          callback err, uris
      else
        callback err, uris

saveItemsFromPageAndQueueNext = (store, callback) ->
  (err, result) ->
    if result.body is ''
      changeRemains store, '-', callback, new Error("Error: #{result.uri} return empty content")
    else
      env result.body, (errors, window) ->
        if errors
          changeRemains store, '-', callback, new Error('cannot make jsdom')
          return
        $ = jquery window
        if $('.item-not-found').length > 0
          log "id:#{store['store_id']} #{store['store_name']} has one empty page: #{result.uri}"
          bannedError = new Error('been banned by taobao')
          changeRemains store, '-', callback, bannedError
        else
          nextUri = nextPageUri $
          if nextUri?
            changeRemains store, '+', callback
            fetchStorePage(makeSureProtocol(nextUri), 'POST', banned)
              .then (res) ->
                saveItemsFromPageAndQueueNext(store, callback)(null, res)
              .catch (err) ->
                saveItemsFromPageAndQueueNext(store, callback)(err, null)
          items = extractItemsFromContent $, store
          bannedError = new Error('been banned by taobao') if isBanned $
          if bannedError
            log 'exiting with code: 99'
            process.exit 99
          pageNumber = currentPageNumber $
          db.saveItems store['store_id'], store['store_name'], items, result.uri, $(TEMPLATES[0].CAT_SELECTED).text().trim(), pageNumber, ->
            changeRemains store, '-', callback, bannedError
        window.close()

nextPageUri = ($) ->
  if $('div.pagination a.next').length > 0
    $('div.pagination a.next').attr('href')
  else if $('.J_SearchAsync').length > 0
    nextUrl = $('div.pagination a:eq(1)').attr('href')
    if nextUrl then return nextUrl.replace('search', 'i/asynSearch').replace(/&amp;pageNo=/g, '&pageNo=') else return null
  else
    log 'exiting with code: 94'
    process.exit 94 # FIXME: 还不清楚具体错误原因，所以快速中断脚本，由forever重启
    throw new Error('cannot get next page uri')

currentPageNumber = ($) ->
  (parseInt $('div.pagination a.page-cur').text()) || 1

extractCatsTreeHtml = ($, store) ->
  catsTreeHtml = ''
  for template in TEMPLATES
    if $(template.CATS_TREE).length > 0
      html = $(template.CATS_TREE).parent().html().trim()
      catsTreeHtml = template.REPLACE html, store
      break
  if catsTreeHtml is ''
    error "id:#{store['store_id']} #{store['store_name']}: catsTreeHtml is empty."
  catsTreeHtml

makeSureProtocol = (uri) ->
  protocol = ''
  protocol = 'http:' if uri.indexOf('http') isnt 0 and uri.indexOf('//') is 0
  protocol + uri

exports.extractItemsFromContent = extractItemsFromContent = ($, store) ->
  items = []
  for template in TEMPLATES
    ITEM = selectRightTemplate $('body'), template.ITEM
    if $(ITEM).length > 0
      $(ITEM).each (index, element) ->
        $item = $(element)
        ITEM_NAME = selectRightTemplate $item, template.ITEM_NAME
        PRICE = selectRightTemplate $item, template.PRICE
        items.push
          goodsName: $item.find(ITEM_NAME).text().trim()
          defaultImage: makeSureProtocol extractDefaultImage $item
          price: parsePrice $item.find(PRICE).text().trim(), store['see_price'], $item.find(ITEM_NAME).text().trim()
          taobaoPrice: parsePrice $item.find(PRICE).text().trim()
          goodHttp: makeSureProtocol $item.find(ITEM_NAME).attr('href')
      break
  filterItems items

selectRightTemplate = ($item, template) ->
  if Array.isArray template
    for t in template
      if $item.find(t).length > 0
        return t
  if Array.isArray template then return template[0] else return template

isBanned = ($) ->
  $('.search-result').length is 0 and $('dl.item').length is 0

banned = (body) ->
  body.indexOf('search-result') is -1 and body.indexOf('class="item') is -1

extractDefaultImage = ($item) ->
  defaultImage = $item.find('img').attr('src')
  if ~defaultImage.indexOf('a.tbcdn.cn/s.gif') or ~defaultImage.indexOf('assets.alicdn.com/s.gif') then defaultImage = $item.find('img').attr('data-ks-lazyload')
  if ~defaultImage.indexOf('40x40')
    console.log $item.html()
    log 'exiting with code: 96'
    process.exit 96
  defaultImage

exports.parsePrice = parsePrice = (price, seePrice = '实价', goodsName = '') ->
  rawPrice = parseFloat price
  finalPrice = rawPrice
  if not seePrice? then finalPrice = formatPrice rawPrice
  if seePrice.indexOf('减半') isnt -1
    finalPrice = formatPrice(rawPrice / 2)
  else if seePrice is 'P' or seePrice is '减P' or seePrice is '减p'
    if /[Pp](\d+(\.\d+)?)/.test goodsName
      finalPrice = parseFloat /[Pp](\d+(\.\d+)?)/.exec(goodsName)?[1]
    else if /[Ff](\d+(\.\d+)?)/.test goodsName
      finalPrice = parseFloat /[Ff](\d+(\.\d+)?)/.exec(goodsName)?[1]
  else if seePrice.indexOf('减') is 0
    finalPrice = formatPrice(rawPrice - parseFloat(seePrice.substr(1)))
  else if seePrice is '实价'
    finalPrice = formatPrice rawPrice
  else if seePrice.indexOf('*') is 0
    finalPrice = formatPrice(rawPrice * parseFloat(seePrice.substr(1)))
  else if seePrice.indexOf('打') is 0
    finalPrice = formatPrice(rawPrice * (parseFloat(seePrice.substr(1)) / 10))
  else if seePrice.indexOf('折') is seePrice.length - 1
    finalPrice = formatPrice(rawPrice * (parseFloat(seePrice) / 10))
  if isNaN(finalPrice) isnt true
    finalPrice
  else
    error "不支持该see_price: #{price} #{seePrice} #{goodsName}"
    rawPrice

formatPrice = (price) ->
  newPrice = parseFloat(price).toFixed 2
  if ~newPrice.indexOf('.') and newPrice.split('.')[1] is '00'
    newPrice.split('.')[0]
  else
    newPrice

filterItems = (unfilteredItems) ->
  items = item for item in unfilteredItems when item.goodsName? and
    item.goodsName isnt '' and
    item.defaultImage? and
    not ~item.goodsName.indexOf('邮费') and
    not ~item.goodsName.indexOf('运费') and
    not ~item.goodsName.indexOf('淘宝网 - 淘！我喜欢') and
    not ~item.goodsName.indexOf('专拍') and
    not ~item.goodsName.indexOf('数据包') and
    not ~item.goodsName.indexOf('邮费') and
    not ~item.goodsName.indexOf('手机套') and
    not ~item.goodsName.indexOf('手机壳') and
    not ~item.goodsName.indexOf('定金') and
    not ~item.goodsName.indexOf('订金') and
    not ~item.goodsName.indexOf('下架') and
    not ~item.defaultImage.indexOf('http://img.taobao.com/newshop/nopicture.gif') and
    not ~item.defaultImage.indexOf('http://img01.taobaocdn.com/bao/uploaded/_180x180.jpg') and
    not ~item.defaultImage.indexOf('http://img01.taobaocdn.com/bao/uploaded/_240x240.jpg') and
    not ~item.defaultImage.indexOf('http://img01.taobaocdn.com/bao/uploaded/_160x160.jpg') and
    not (item.price <= 0)

exports.getNumIidFromUri = getNumIidFromUri = (uri) ->
  matches = /item\.htm\?.*id=(\d+)/.exec uri
  if matches?
    matches[1]
  else
    throw new Error('there is no numIid in uri')

exports.parseSkus = parseSkus = (itemSkus, propertyAlias = null, seePrice, title) ->
  skuArray = itemSkus?.sku || []
  skus = []
  for sku in skuArray
    propertiesNameArray = sku.properties_name.split ';'
    properties = []
    for propertiesName in propertiesNameArray
      [pid, vid, name, value] = propertiesName.split ':'
      if propertyAlias? then value = getPropertyAlias propertyAlias, vid, value
      properties.push
        pid: pid
        vid: vid
        name: name
        value: value
        price: parsePrice sku.price, seePrice, title
        taobaoPrice: parsePrice sku.price
        quantity: sku.quantity
    skus.push properties
  skus
# 获取标准商品类目属性
parseAttrs = (propsName, propertyAlias = null) ->
  attrs = []
  if propsName
    propsArray = propsName.split ';'
    for props in propsArray
      [attrId, valueId, attrName, attrValue] = props.split ':'
      if propertyAlias? then attrValue = getPropertyAlias propertyAlias, valueId, attrValue
      found = false
      for attr in attrs
        if attr.attrId is attrId
          attr.valueId = attr.valueId + ',' + valueId
          attr.attrValue = attr.attrValue + ',' + attrValue
          found = true
      if not found
        attrs.push
          attrId: attrId
          valueId: valueId
          attrName: attrName
          attrValue: attrValue.replace "'", "\\'"
  attrs

getPropertyAlias = (propertyAlias, valueId, value) ->
  retVal = value
  position = propertyAlias.indexOf valueId
  if position isnt -1
    nextPosition = propertyAlias.indexOf ';', position
    if nextPosition is -1 then nextPosition = propertyAlias.length
    propertyString = propertyAlias.substring position, nextPosition
    retVal = propertyString.split(':')[1]
  retVal
# 获取商品类目id. CID 
getHierarchalCats = (cid, callback) ->
  cats = []
  next = (err, itemcats) ->
    if err or itemcats.length is 0
      callback err, cats
    else
      cats.push itemcats[0]
      if itemcats[0].parent_cid is 0
        callback null, cats
      else
        getItemCats itemcats[0].parent_cid, 'name, cid, parent_cid', next
  getItemCats cid, 'name, cid, parent_cid', next

exports.removeSingleQuotes = removeSingleQuotes = (content) ->
  content.replace /'/g, ''

makeOuterId = (store, huohao, price) ->
  seller = store.shop_mall + store.dangkou_address
  "#{seller}_P#{price}_#{huohao}#"

getHuoHaoFromAttrs = (attrs) ->
  for attr in attrs
    if attr.attrName is '货号' or attr.attrName is '款号'
      return attr.attrValue.replace '#', ''
  return ''

exports.isRealPic = isRealPic = (title, propsName) ->
  if ~title.indexOf('实拍') or ~propsName.indexOf('157305307')
    1
  else
    0

fetchStorePage = (url, method, banned, prevFetchContent = '') ->
  fetch url, method, null
    .then (res) ->
      if res.statusCode is 302
        if res.headers['location'] is 'https://store.taobao.com/shop/noshop.htm'
          throw new Error("302 to noshop.htm while requesting url #{url}")
        debug "302 found, redirect to #{res.headers['location']}"
        fetchStorePage res.headers['location'], method, banned, prevFetchContent
      else if ~res.body.indexOf('J_ShopAsynSearchURL')
        asynUrl = getAsynSearchURL(res.body)
        debug "AsynSearch found: #{asynUrl}"
        fetchStorePage asynUrl, method, banned, res.body
      else
        if prevFetchContent
          res.body += prevFetchContent
        res.body = res.body.replace(/\\"/g, '"');
        res

getAsynSearchURL = (body) ->
  asynRegex = /.+J_ShopAsynSearchURL.+value=\"(.+)\"/
  asynMatches = body.match asynRegex
  asynURL = asynMatches[1].replace(/&amp;pageNo=/g, '&pageNo=')
  shopRegex = /(\w+)\.taobao\.com\/search.htm/
  shopMatches = body.match shopRegex
  shopURL = "#{shopMatches[1]}.taobao.com"
  "https://#{shopURL}#{asynURL}&orderType=newOn_desc"

exports.$fetch = $fetch = (url, callback) ->
  fetch url, 'GET'
    .then (result) ->
      body = result.body
      makeJsDomPromise body
    .then (window) ->
      $ = jquery window
      callback $
      window.close()
    .then undefined, (reason) -> throw new Error(reason)

crawlDesc = (url) ->
  defered = Q.defer()
  fetch url, 'GET'
    .then (result) ->
      body = result.body
      if ~body.indexOf 'var desc'
        desc = body.replace "var desc='", ''
        desc = desc.replace new RegExp('"//img', 'g'), '"http://img'
        desc = desc.substr 0, desc.length - 2
        defered.resolve desc
      else
        defered.reject new Error 'desc response text does not contain valid content'
    .catch (reason) ->
      defered.reject reason
  defered.promise

extractDescUrl = (html) ->
  descUrl = null
  matches = /location.protocol==='http:' \? '(.+)' : '(.+)'/.exec html
  if matches? then descUrl = 'https:' + matches[2]
  if not descUrl?
    matches = /descUrl\s*:\s*['"](.+)['"]/.exec html
    if matches? then descUrl = 'https:' + matches[1]
  if not descUrl? then throw new Error("fail to crawl because of no desc url")
  descUrl

extractSkus = ($, defaultPrice) ->
  skus = sku: []
  skuMap = extractSkuMap $('html').html()
  $sizeLis = $('.J_Prop_measurement li')
  $colorLis = $('.J_Prop_Color li')
  if $sizeLis.length > 0 and $colorLis.length > 0
    for colorLi in $colorLis
      for sizeLi in $sizeLis
        $colorLi = $ colorLi
        $sizeLi = $ sizeLi
        colorProp = $colorLi.attr('data-value')
        sizeProp = $sizeLi.attr('data-value')
        price = skuPrice colorProp, sizeProp, skuMap, defaultPrice
        skus.sku.push
          price: price
          properties: "#{colorProp};#{sizeProp}"
          properties_name: "#{colorProp}:#{$('.J_Prop_Color .tb-property-type').text()}:#{$colorLi.find('span').text()};#{sizeProp}:#{$('.J_Prop_measurement .tb-property-type').text()}:#{$sizeLi.find('span').text()}"
          quantity: 999
  else
    $oneLis = if $sizeLis.length > 0 then $sizeLis else $colorLis
    oneSelector = if $sizeLis.length > 0 then '.J_Prop_measurement' else '.J_Prop_Color'
    for oneLi in $oneLis
      $oneLi = $ oneLi
      oneProp = $oneLi.attr('data-value')
      price = skuPrice oneProp, '', skuMap, defaultPrice
      skus.sku.push
        price: price
        properties: "#{oneProp}"
        properties_name: "#{oneProp}:#{$(oneSelector + ' .tb-property-type').text()}:#{$oneLi.find('span').text()}"
        quantity: 999
  skus

skuPrice = (p1, p2, skuMap, defaultPrice) ->
  if skuMap[";#{p1};#{p2};"]
    skuMap[";#{p1};#{p2};"].price
  else if skuMap[";#{p2};#{p1};"]
    skuMap[";#{p2};#{p1};"].price
  else if skuMap[";#{p1};"]
    skuMap[";#{p1};"].price
  else
    defaultPrice

extractSkuMap = (html) ->
  matches = /skuMap +: +(.+)/.exec html
  if matches?
    JSON.parse matches[1]
  else
    {}

extractItemImgs = ($) ->
  itemImgs = item_img: []
  if $('.tb-thumb li').length > 0
    $('.tb-thumb li').each ->
      $li = $ @
      itemImgs.item_img.push
        url: makeSureProtocol $li.find('img').attr('data-src').replace('_50x50.jpg', '')
  else if $('.tb-thumb-nav li').length > 0
    $('.tb-thumb-nav li').each ->
      $li = $ @
      itemImgs.item_img.push
        url: makeSureProtocol $li.find('img').attr('src').replace('_70x70.jpg', '')
  else
    throw new Error("fail to crawl because of no item imgs")
  itemImgs

extractCid = (html) ->
  cid = null
  matches = /[^r]cid\s*:\s*'(\d+)'/.exec html
  if matches? then cid = parseInt matches[1]
  if not cid? then throw new Error("fail to crawl because of no cid")
  cid

extractNick = (html) ->
  nick = null
  matches = /sellerNick\s*:\s*'(.+)'/.exec html
  if matches? then nick = matches[1]
  if not nick?
    matches = /nick\s*:\s*['"](.+)['"]/.exec html
    if matches? then nick = matches[1]
  if not nick? then throw new Error("fail to crawl because of no nick")
  nick

extractTitle = ($) ->
  title = $('.tb-main-title').attr('data-title');
  if not title then title = $('.tb-main-title').text();
  if not title then throw new Error("fail to crawl because of no title")
  title

extractPicUrl = ($) ->
  if $('.tb-thumb li:eq(0) img').attr('data-src')
    makeSureProtocol $('.tb-thumb li:eq(0) img').attr('data-src').replace('_50x50.jpg', '');
  else if $('.tb-thumb-content img').attr('src')
    makeSureProtocol $('.tb-thumb-content img').attr('src').replace('_600x600.jpg', '');
  else
    throw new Error("fail to crawl because of no pic url")

findPid = (pname, props) ->
  for prop in props
    if prop.name is pname then return prop.pid
  0

findVid = (vname, pid, props) ->
  for prop in props
    if prop.pid is pid and prop.prop_values?.prop_value?
      for value in prop.prop_values.prop_value
        if value.name is vname then return value.vid
      return prop.prop_values.prop_value[0]?.vid || 0
  0

extractPropsName = ($, cid) ->
  defered = Q.defer()
  attrs = []
  $('.attributes-list li').each ->
    $li = $ @
    [pname, vname] = $li.text().split(':')
    pname = pname.trim()
    vname = vname.trim()
    attrs.push "#{pname}:#{vname}"
  getItemProps cid, 'pid,name,must,multi,prop_values,is_key_prop,is_sale_prop,parent_vid,is_enum_prop', null, (err, props) ->
    if err
      defered.reject err
    else
      propsName = ''
      for attr in attrs
        [pname, vname] = attr.split ':'
        pid = findPid pname, props
        vid = findVid vname, pid, props
        propsName += "#{pid}:#{vid}:#{attr};"
      if propsName.length > 0 then propsName = propsName.substr 0, propsName.length - 1
      defered.resolve propsName
  defered.promise

exports.crawlTaobaoItem = crawlTaobaoItem = (numIid, callback, retryTimes = 0) ->
  if retryTimes >= CRAWL_ITEM_RETRY_TIMES
    callback new Error("good #{numIid} fail to crawl after retry #{CRAWL_ITEM_RETRY_TIMES} times")
    return
  url = "https://item.taobao.com/item.htm?id=#{numIid}"
  $fetch url, ($) ->
    if $('.error-notice-hd').length > 0 or $('.J_TOffSale').length > 0
      callback new Error("num_iid: #{numIid} fail to crawl because of taken off shelves")
      return
    taobaoItem = {}

    # 有2种模版的html会返回，第2种没有cid，所以切换ip代理重新抓取，看看能不能获得第1种模版来处理
    # 这样的处理方式导致后面的所有extractX方法支持2种模版变得没有意义，以后再回来想办法优化吧
    err = null
    try
      taobaoItem.cid = extractCid $('html').html()
    catch e
      err = e
      error new Error("good #{numIid} fail to crawl", e)
      crawlTaobaoItem numIid, callback, ++retryTimes
    if err? then return

    taobaoItem.title = extractTitle $
    taobaoItem.pic_url = extractPicUrl $
    taobaoItem.price = $('.tb-rmb-num').text()
    taobaoItem.skus = extractSkus $, taobaoItem.price
    taobaoItem.property_alias = ''
    taobaoItem.item_imgs = extractItemImgs $
    taobaoItem.nick = extractNick $('html').html()
    descUrl = extractDescUrl $('html').html()
    if not taobaoItem.title or not taobaoItem.price or not descUrl
      throw new Error "num_iid: #{numIid} fail to crawl"
    extractPropsName $, taobaoItem.cid
      .then (propsName) ->
        taobaoItem.props_name = propsName
        crawlDesc descUrl
      .then (desc) ->
        log "fetched taobao item: #{inspect(taobaoItem, {depth: null})}"
        taobaoItem.desc = desc
        callback null, taobaoItem
      .catch (reason) ->
        callback reason, null

if process.env.NODE_ENV is 'test' or process.env.NODE_ENV is 'e2e'
  exports.setSaveItemsFromPageAndQueueNext = (f) -> saveItemsFromPageAndQueueNext = f
  exports.setCrawlAllPagesOfByNew = (f) -> crawlAllPagesOfByNew = f
  exports.setCrawlAllPagesOfAllCates = (f) -> crawlAllPagesOfAllCates = f
  exports.setClearCids = (f) -> clearCids = f
  exports.setDeleteDelistItems = (f) -> deleteDelistItems = f
  exports.setChangeRemains = (f) -> changeRemains = f
  exports.setCrawlItemViaApi = (f) -> crawlItemViaApi = f
  exports.setFetch = (f) -> fetch = f
  exports.set$Fetch = (f) -> $fetch = f
  exports.setGetItemProps = (f) -> getItemProps = f
  exports.setGetHierarchalCats = (f) -> getHierarchalCats = f
  exports.parsePrice = parsePrice
  exports.formatPrice = formatPrice
  exports.crawlAllPagesOfByNew = crawlAllPagesOfByNew
  exports.crawlAllPagesOfAllCates = crawlAllPagesOfAllCates
  exports.saveItemsFromPageAndQueueNext = saveItemsFromPageAndQueueNext
  exports.getNumIidFromUri = getNumIidFromUri
  exports.parseSkus = parseSkus
  exports.parseAttrs = parseAttrs
  exports.removeSingleQuotes = removeSingleQuotes
  exports.makeOuterId = makeOuterId
  exports.extractCatsTreeHtml = extractCatsTreeHtml
  exports.extractUris = extractUris
  exports.extractImWw = extractImWw
  exports.filterItems = filterItems
  exports.isRealPic = isRealPic
  exports.changeRemains = changeRemains
  exports.getPropertyAlias = getPropertyAlias
  exports.crawlDesc = crawlDesc
  exports.extractDescUrl = extractDescUrl
  exports.extractSkus = extractSkus
  exports.extractSkuMap = extractSkuMap
  exports.extractItemImgs = extractItemImgs
  exports.extractCid = extractCid
  exports.extractNick = extractNick
  exports.extractPropsName = extractPropsName
  exports.queueStoreUri = queueStoreUri
  exports.fetch = fetch
  exports.getHierarchalCats = getHierarchalCats
  exports.getAsynSearchURL = getAsynSearchURL
