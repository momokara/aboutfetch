{getItemCats} = require '../src/taobao_api'
args = process.argv.slice 2

getItemCats args[0], 'cid,parent_cid,name,is_parent', (err, cats) ->
  if err then return console.error err
  console.log cats
