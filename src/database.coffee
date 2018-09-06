mysql = require 'mysql'
config = require './config'
{log, error, getHuoHao} = require './util'
Q = require 'q'

class db
  constructor: (databaseConfig) ->
    if databaseConfig? then cfg = databaseConfig else cfg = config.database['ecmall51_2']
    cfg.multipleStatements = true
    @updateStoreCateContentCounter = 0
    @updateImWwCounter = 0
    @clearCidsCounter = 0
    @deleteDelistItemsCounter = 0
    @saveItemsCounter = 0
    @pool = mysql.createPool cfg

  query: (sql, callback) ->
    @pool.query sql, (err, result) =>
      if err?.code is 'PROTOCOL_CONNECTION_LOST'
        @query sql, callback
      else
        callback err, result

  $query: (sql) ->
    deferred = Q.defer()
    @query sql, deferred.makeNodeResolver()
    deferred.promise

  runSql: (sql, callback) ->
    @query sql, (err, result) ->
      callback err, result
# 获取商品信息
  getStores: (condition, callback) ->
    @query "select * from ecm_store where #{condition}", (err, result) ->
      callback err, result

  getUnfetchedStores: (callback) ->
    @query "select * from ecm_store s where not exists (select 1 from ecmall51_2.ecm_store s2 where s2.shop_mall = s.shop_mall and s2.address = s.address and s2.floor = s.floor) and not exists (select 1 from ecmall51_2.ecm_store s2 where s2.im_qq = s.im_qq) order by s.store_id", (err, result) ->
      callback err, result

  getUnfetchedGoods: (callback) ->
    @query "select * from ecm_goods g where g.good_http is not null and not exists (select 1 from ecm_goods_spec s where s.goods_id = g.goods_id)", (err, result) ->
      callback err, result

# 获取没有更新的商品
  getUnfetchedGoodsInStore: (storeId, callback) ->
    @query "select * from ecm_goods g where g.store_id = #{storeId} and g.good_http is not null and not exists (select 1 from ecm_goods_spec s where s.goods_id = g.goods_id)", (err, result) ->
      callback err, result
# 从商品中获取某个商品
  getOneGoodInStore: (goodsId, callback) ->
    @query "select * from ecm_goods g where g.goods_id = #{goodsId} and g.good_http is not null", (err, result) ->
      callback err, result

  getAllGoodsInStore: (storeId, callback) ->
    @query "select * from ecm_goods g where g.store_id = #{storeId} and g.good_http is not null", (err, result) ->
      callback err, result

  getGoodsWithRemoteImage: (callback) ->
    @query "select * from ecm_goods g where g.default_image like '%taobaocdn.com%'", (err, result) ->
      callback err, result

  getGood: (goodHttp, callback) ->
    @query "select * from ecm_goods where good_http = '#{goodHttp}'", (err, result) ->
      if err
        error "error in getGood: #{goodHttp}"
      callback err, result[0]
# 更新商品信息
  updateGoods: (goodsId, title, price, taobaoPrice, desc, goodHttp, realPic, skus, defaultImage, sellerCids, callback) ->
    sql = ''
    if sellerCids
      cids = sellerCids.split ','
      for cid in cids
        if cid then sql += "replace into ecm_category_goods(cate_id, goods_id) values (#{cid}, #{goodsId});"
    specName1 = skus[0]?[0]?.name || ''
    specName2 = skus[0]?[1]?.name || ''
    specPid1 = skus[0]?[0]?.pid || 0
    specPid2 = skus[0]?[1]?.pid || 0
    specQty = skus[0]?.length || 0
    sql += "update ecm_goods set goods_name = #{@pool.escape(title)}, price = #{price}, taobao_price = #{taobaoPrice}, description = '#{desc}', spec_name_1 = '#{specName1}', spec_name_2 = '#{specName2}', spec_pid_1 = #{specPid1}, spec_pid_2 = #{specPid2}, spec_qty = #{specQty}, realpic = #{realPic} where good_http = '#{goodHttp}';"
    sql += "update ecm_goods set default_image = '#{defaultImage}' where good_http = '#{goodHttp}' and (default_image = '' or default_image = 'undefined' or locate('resweb.com', default_image) != 0);"
    @query sql, (err, result) ->
      if err
        error "error in update goods: #{goodHttp}"
      callback err, result

  updateCats: (goodsId, storeId, cats, callback) ->
    sql = ''
    gcategorySql = ''
    goodsSql = ''
    cateSql = ''
    cat = cats.pop()
    gcategorySql = "insert into ecm_gcategory(cate_id, store_id, cate_name, parent_id) values (#{cat.cid}, 0, '#{cat.name}', #{cat.parent_cid}) on duplicate key update store_id = 0, cate_name = '#{cat.name}', parent_id = #{cat.parent_cid};"
    goodsSql = "update ecm_goods set cate_id_1 = #{cat.cid}"
    i = 1
    while cats.length > 0
      cat = cats.pop()
      cateId = cat.cid
      cateName = cat.name
      parentCid = cat.parent_cid
      gcategorySql += "insert into ecm_gcategory(cate_id, store_id, cate_name, parent_id) values (#{cateId}, 0, '#{cateName}', #{parentCid}) on duplicate key update store_id = 0, cate_name = '#{cateName}', parent_id = #{parentCid};"
      goodsSql += ", cate_id_#{++i} = #{cateId}"
      if cats.length is 0
        cateSql = "update ecm_goods set cate_id = #{cat.cid} where goods_id = #{goodsId};"
    goodsSql += " where goods_id = #{goodsId};"
    sql = gcategorySql + goodsSql + cateSql
    @query sql, (err, result) ->
      callback err, result

  updateDefaultSpec: (goodsId, specId, callback) ->
    @query "update ecm_goods set default_spec = #{specId} where goods_id = #{goodsId}", (err, result) ->
      if err
        error "error in update default spec, goodsId:#{goodsId}, specId:#{specId}"
      callback err, result

  updateSpecs: (skus, goodsId, price, taobaoPrice, huohao, callback) ->
    oldSpecsInDb = null
    @getSpecs goodsId
      .then (oldSpecs) =>
        oldSpecsInDb = oldSpecs
        sql = ''
        newSpecs = []
        # FIXME: if skus is undefined then quantity should get value from item instead
        quantity = 1000
        for sku in skus
          spec1 = sku[0]?.value
          spec2 = sku[1]?.value || ''
          specVid1 = sku[0]?.vid || 0
          specVid2 = sku[1]?.vid || 0
          quantity = sku[0]?.quantity || 1000
          newSpecs.push
            goods_id: goodsId
            spec_1: spec1
            spec_2: spec2
            spec_vid_1: specVid1
            spec_vid_2: specVid2
            price: sku[0]?.price || price
            stock: quantity
            sku: huohao
            taobao_price: sku[0]?.taobaoPrice || taobaoPrice
        if skus.length is 0
          if oldSpecs.length is 0
            sql = "insert into ecm_goods_spec(goods_id, spec_1, spec_2, spec_vid_1, spec_vid_2, price, stock, sku, taobao_price) values ('#{goodsId}', '', '', '0', '0', '#{price}', '#{quantity}', '#{huohao}', '#{taobaoPrice}');"
          else if oldSpecs.length is 1 and oldSpecs[0].spec_1 is '' and oldSpecs[0].spec_2 is ''
            sql = "update ecm_goods_spec set price = '#{price}', stock = '#{quantity}', sku = '#{huohao}', taobao_price = '#{taobaoPrice}' where spec_id = #{oldSpecs[0].spec_id};"
        else
          sql = @makeUpdateSpecsSql oldSpecs, newSpecs
        @$query sql
      .then (result) ->
        if result.insertId?
          if result.insertId > 0
            insertId = result.insertId
          else
            insertId = oldSpecsInDb[0].spec_id
        else if result.length > 0
          found = false
          for affect in result
            if affect.insertId > 0
              insertId = affect.insertId
              found = true
              break
          if not found then insertId = oldSpecsInDb[0].spec_id
        callback null,
          insertId: insertId
      .catch (err) ->
        error "error in updateSpecs, goodsId:#{goodsId}, error:#{err}"
        callback err, null

  makeUpdateSpecsSql: (oldSpecs, newSpecs) ->
    sql = ''
    processed = []
    for os in oldSpecs
      found = false
      for ns, i in newSpecs
        if os.spec_1 == ns.spec_1 and os.spec_2 == ns.spec_2 and os.spec_vid_1 == ns.spec_vid_1 and os.spec_vid_2 == ns.spec_vid_2
          sql += "update ecm_goods_spec set price = '#{ns.price}', stock = '#{ns.stock}', sku = '#{ns.sku}', taobao_price = '#{ns.taobao_price}' where spec_id = #{os.spec_id};"
          found = true
          processed.push i
          break
      if not found then sql += "delete from ecm_goods_spec where spec_id = #{os.spec_id};"
    for ns, i in newSpecs
      if not ~processed.indexOf i then sql += "insert into ecm_goods_spec(goods_id, spec_1, spec_2, spec_vid_1, spec_vid_2, price, stock, sku, taobao_price) values ('#{ns.goods_id}', '#{ns.spec_1}', '#{ns.spec_2}', '#{ns.spec_vid_1}', '#{ns.spec_vid_2}', '#{ns.price}', '#{ns.stock}', '#{ns.sku}', '#{ns.taobao_price}');"
    sql

  getSpecs: (goodsId) ->
    @$query "select * from ecm_goods_spec where goods_id = #{goodsId}"

  updateStoreCateContent: (storeId, storeName, cateContent) ->
    @updateStoreCateContentCounter += 1
    @query "update ecm_store set cate_content='#{cateContent}' where store_id = #{storeId}", (err, result) =>
      @updateStoreCateContentCounter -= 1
      if err
        return error "error in updateStoreCateContent: #{storeId} #{storeName} " + err
      log "id:#{storeId} #{storeName} updated cate_content."

  updateImWw: (storeId, storeName, imWw) ->
    @updateImWwCounter += 1
    @query "update ecm_store set im_ww = '#{imWw}' where store_id = #{storeId}", (err, result) =>
      @updateImWwCounter -= 1
      if err
        return error "error in updateImWw: #{storeId} #{storeName} #{imWw} " + err
      log "id:#{storeId} #{storeName} updated im_ww #{imWw}."

  updateItemImgs: (goodsId, itemImgs, callback) ->
    @getItemImgs goodsId
      .then (oldItemImgs) =>
        newItemImgs = []
        for img, i in itemImgs
          newItemImgs.push
            goods_id: goodsId
            image_url: img.url
            thumbnail: "#{img.url}_460x460.jpg"
            sort_order: i
            file_id: 0
        @$query @makeUpdateItemImgsSql oldItemImgs, newItemImgs
      .then (result) ->
        callback null, result
      .catch (err) ->
        error "error in updateItemImgs, goodsId:#{goodsId}, error:#{err}"
        callback err, null

  makeUpdateItemImgsSql: (oldItemImgs, newItemImgs) ->
    sql = ''
    delta = oldItemImgs.length - newItemImgs.length
    if delta >= 0
      for oii, i in oldItemImgs
        if i < newItemImgs.length
          sql += "update ecm_goods_image set goods_id = '#{newItemImgs[i].goods_id}', image_url = '#{newItemImgs[i].image_url}', thumbnail = '#{newItemImgs[i].thumbnail}', sort_order = '#{newItemImgs[i].sort_order}', file_id = '#{newItemImgs[i].file_id}' where image_id = #{oii.image_id};"
        else
          sql += "delete from ecm_goods_image where image_id = #{oii.image_id};"
    else
      for nii, j in newItemImgs
        if j < oldItemImgs.length
          sql += "update ecm_goods_image set goods_id = '#{nii.goods_id}', image_url = '#{nii.image_url}', thumbnail = '#{nii.thumbnail}', sort_order = '#{nii.sort_order}', file_id = '#{nii.file_id}' where image_id = #{oldItemImgs[j].image_id};"
        else
          sql += "insert into ecm_goods_image(goods_id, image_url, thumbnail, sort_order, file_id) values ('#{nii.goods_id}', '#{nii.image_url}', '#{nii.thumbnail}', '#{nii.sort_order}', '#{nii.file_id}');"
    sql

  getItemImgs: (goodsId) ->
    @$query "select * from ecm_goods_image where goods_id = #{goodsId} order by sort_order;"

  saveItemAttr: (goodsId, attrs, callback) ->
    @getItemAttr goodsId
      .then (oldItemAttr) =>
        newItemAttr = []
        for attr in attrs
          {attrId, valueId, attrName, attrValue} = attr
          newItemAttr.push
            goods_id: goodsId
            attr_name: attrName
            attr_value: attrValue
            attr_id: attrId
            value_id: valueId
        @$query @makeSaveItemAttrSql oldItemAttr, newItemAttr
      .then (result) ->
        callback null, result
      .catch (err) ->
        error "error in saveItemAttr, goodsId:#{goodsId}, error:#{err}"
        callback err, null

  makeSaveItemAttrSql: (oldItemAttr, newItemAttr) ->
    sql = ''
    processed = []
    for oia in oldItemAttr
      found = false
      for nia, i in newItemAttr
        if oia.attr_id == nia.attr_id and oia.value_id == nia.value_id
          sql += "replace into ecm_attribute(attr_id, attr_name, input_mode, def_value) values ('#{nia.attr_id}', '#{nia.attr_name}', 'select', '其他');update ecm_goods_attr set attr_name = '#{nia.attr_name}', attr_value = '#{nia.attr_value}' where gattr_id = #{oia.gattr_id};"
          found = true
          processed.push i
          break
      if not found then sql += "delete from ecm_goods_attr where gattr_id = #{oia.gattr_id};"
    for nia, i in newItemAttr
      if not ~processed.indexOf i then sql += "replace into ecm_attribute(attr_id, attr_name, input_mode, def_value) values ('#{nia.attr_id}', '#{nia.attr_name}', 'select', '其他');insert into ecm_goods_attr(goods_id, attr_name, attr_value, attr_id, value_id) values ('#{nia.goods_id}', '#{nia.attr_name}', '#{nia.attr_value}', '#{nia.attr_id}', '#{nia.value_id}');"
    sql

  getItemAttr: (goodsId) ->
    @$query "select * from ecm_goods_attr where goods_id = #{goodsId}"

  saveItems: (storeId, storeName, items, url, catName, pageNumber, callback) ->
    @saveItemsCounter += 1
    sql = @makeSaveItemSql storeId, storeName, items, @getCidFromUrl(url), catName, pageNumber
    @query sql, (err, result) =>
      @saveItemsCounter -= 1
      if err
        error "error in saveItems: #{err}"
      else
        log "id:#{storeId} #{storeName} fetched pageNo: #{pageNumber} cid: #{@getCidFromUrl url} counts: #{items.length}."
      callback err, result

  clearCids: (storeId, callback) ->
    @clearCidsCounter += 1
    @query "update ecm_goods set cids = '' where store_id = #{storeId}", (err, result) =>
      @clearCidsCounter -= 1
      callback err, result

  deleteDelistItems: (storeId, totalItemsCount, callback) ->
    @deleteDelistItemsCounter += 1
    @query "select count(1) totalCount from ecm_goods where store_id = #{storeId};select count(1) delistCount from ecm_goods where store_id = #{storeId} and last_update < #{@oneHourAgo()}", (err, results) =>
      totalCount = parseInt(results[0][0]['totalCount'])
      delistCount = parseInt(results[1][0]['delistCount'])
      if delistCount > 0
        @query "call delete_goods(#{@oneHourAgo()}, #{storeId}, #{storeId+1}, @o_count)", (err, result) =>
          if err then error "call delete_goods(#{@oneHourAgo()}, #{storeId}, #{storeId+1}, @o_count)"
          @deleteDelistItemsCounter -= 1
          log "id:#{storeId} totalCount:#{totalCount} delistedCount: #{result[0][0].o_count} totalItemsCount:#{totalItemsCount}"
          callback err, result
      else
        @deleteDelistItemsCounter -= 1
        log "id:#{storeId} totalCount:#{totalCount} delistCount:#{delistCount} totalItemsCount:#{totalItemsCount}"
        callback null, null

  buildOuterIid: (storeId, callback) ->
    @query "call build_outer_iid(#{storeId}, #{(parseInt storeId) + 1})", (err, result) ->
      callback err, result

  makeSaveItemSql: (storeId, storeName, items, cid, catName, pageNumber) ->
    sql = ''
    time = @getDateTime() - pageNumber * 60 # 每一页宝贝的time都倒退1分钟，保证最终add_time是按照新款排序的
    if catName isnt '所有宝贝'
      sql += "insert into ecm_gcategory(cate_id, store_id, cate_name, if_show) values ('#{cid}', '#{storeId}', '#{catName}', 1) on duplicate key update store_id = '#{storeId}', cate_name = '#{catName}', if_show = 1;"
    for item, i in items
      huohao = if item.huohao? then item.huohao else getHuoHao(item.goodsName)
      sql += "call proc_merge_good('#{storeId}','#{item.defaultImage}','#{item.price}','#{item.taobaoPrice}','#{item.goodHttp}','#{cid}','#{storeName}',#{@pool.escape(item.goodsName)},'#{time-i}','#{catName}','#{huohao}',@o_retcode);"
    sql

  updateCategories: (storeId, cats, callback) ->
    if cats and storeId > 5000
      sql = "delete from ecm_gcategory where store_id = #{storeId} and cate_mname is null;"
    else
      sql = ''
    for cat in cats
      sql += "insert into ecm_gcategory(cate_id, parent_id, store_id, sort_order, cate_name, if_show) values ('#{cat.cid}', '#{cat.parent_cid}', '#{storeId}', '#{cat.sort_order}', '#{cat.name}', 1) on duplicate key update parent_id = '#{cat.parent_cid}', store_id = '#{storeId}', sort_order = '#{cat.sort_order}', cate_name = '#{cat.name}', if_show = 1;"
    @query sql, (err, result) ->
      callback err, result

  getCidFromUrl: (url) ->
    url.match(/category-(\w+)(-\w+)?.htm/)?[1] || ''

  getDateTime: () ->
    date = new Date()
    dateTime = parseInt(date.getTime() / 1000)
    dateTime

  todayZeroTime: ->
    date = new Date
    date.setHours 0
    date.setMinutes 0
    dateTime = parseInt(date.getTime() / 1000)
    dateTime

  oneHourAgo: ->
    date = new Date
    hour = date.getHours()
    date.setHours (hour - 1)
    dateTime = parseInt(date.getTime() / 1000)
    dateTime

  end: () ->
    @pool.end (err) ->
      if err
        error "error in db.end: " + err
      else
        log "database pool ended."

module.exports = db
