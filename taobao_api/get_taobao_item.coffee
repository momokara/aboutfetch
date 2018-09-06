{getTaobaoItem} = require '../src/taobao_api'
args = process.argv.slice 2

getTaobaoItem args[0], 'title,desc,pic_url,sku,item_weight,property_alias,price,item_img.url,cid,nick,props_name,prop_img,delist_time', (err, item) ->
  if err then return console.error err
  console.log item
