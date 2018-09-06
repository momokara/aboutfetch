{getTaobaoItemsSellerListBatch} = require '../src/taobao_api'
args = process.argv.slice 2

getTaobaoItemsSellerListBatch args[0], 'title,created', args[1], [], (err, items) ->
   if err then return console.error err
   console.log items
