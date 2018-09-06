{getTaobaoItemsOnsale} = require '../src/taobao_api'
args = process.argv.slice 2

getTaobaoItemsOnsale 'title,pic_url,price,num_iid', '1', args[0], (err, res) ->
  if err then return console.error err
  console.log res
