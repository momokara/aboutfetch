{inspect} = require 'util'
{getItemProps} = require '../src/taobao_api'
args = process.argv.slice 2

getItemProps args[0], 'pid,name,must,multi,prop_values,is_key_prop,is_sale_prop,parent_vid,is_enum_prop', null, (err, props) ->
  console.log inspect props, {depth: null}
