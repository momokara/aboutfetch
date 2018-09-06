{getSellercatsList} = require '../src/taobao_api'
args = process.argv.slice 2

getSellercatsList args[0], (err, list) ->
  if err then return console.error err
  console.log list
