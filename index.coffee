# 连接工具
{Pool} = require 'generic-pool' 
# 调用淘宝爬虫
{buildOuterIid, crawlItemsInStore, getAllStores, setDatabase, getDatabase} = require './src/taobao_crawler'
crawlStore = require('./src/crawler').crawlStore
# 数据库连接以及操作
database = require './src/database'
# 项目配置
config = require './src/config'
# 启用代理服务
{getIPProxy} = require './src/crawler'
# 获取参数 第一个是node 第二个是脚本文件 所以从第三个开始获取传入的参数 
# 项目参数 args[0] 数据库名 
# 项目参数 args[1] 当前服务器公网IP地址 
# 项目参数 args[2] 是否全部爬取  --具体功能未验证
# 项目参数 args[3] 是否使用API 爬取 
args = process.argv.slice 2
# 第二个参数
ip = args[1]

# 退出操作
process.on 'exit', (code) ->
  db.query "update ecm_crawl_config set exit_code = #{code} where ip = '#{ip}'", ->
    # 退出日志
    console.log [
      "updateStoreCateContentCounter: #{db.updateStoreCateContentCounter}"
      "updateImWwCounter: #{db.updateImWwCounter}"
      "clearCidsCounter: #{db.clearCidsCounter}"
      "deleteDelistItemsCounter: #{db.deleteDelistItemsCounter}"
      "saveItemsCounter: #{db.saveItemsCounter}"
    ].join ' | '
    console.log "about to exit with code: #{code}"

# 写错误日志
process.on 'uncaughtException', (err) ->
  console.log 'caught exception:' + err
# 连接数据库
db = new database(config.database[args[0]])
setDatabase db

# 判断fullCrawl 当第二个参数是fullCraw的时候返回true
fullCrawl = if args.length >= 3 and args[2] is 'fullCrawl' then true else false
# 调用api爬取
needCrawlItemsViaApi = if args.length is 4 and args[3] is 'api' then true else false
# 重置开始爬取的ID  如果需要
resetNowIdIfNecessary = (crawlConfig) ->
  # 剩余要爬取的ID数量
  remain = parseInt(crawlConfig.end_id) - parseInt(crawlConfig.now_id)
  # 如果剩余数量小于100 则跟新表 ecm_crawl_config 中的now_id 为startid
  if remain < 100
    db.query "update ecm_crawl_config set now_id = start_id where ip = '#{crawlConfig.ip}'", (err) ->
      # 如果抛出错误 写入错误日志
      if err then console.error "fail to reset now id, ip: #{crawlConfig.ip}, error: #{err}" else console.log "success to reset now id, ip: #{crawlConfig.ip}"
  else
    # 剩余的爬取店铺大于100的时候写入日志，继续爬取
    console.log "remain #{remain} stores to update, no need reset now id"

# 创建连接池
pool = Pool
  # 连接名称
  name: 'taobao store crawler',
  # 最大连接数
  max: 10
  # 创建时的回调
  create: (callback) -> callback(1)
  # 销毁时的回调
  destroy: (client) ->

# 店铺列表
stores = []

# 爬取店铺
crawl = (store) ->
# 获取一个连接
  pool.acquire (err, poolRef) ->
  # 如果错误
    if (err)
      # 写入错误日志
      console.error "pool acquire error: #{err}"
      # 释放连接
      pool.release poolRef
      console.log 'exiting with code: 95'
      # 退出
      process.exit 95
  # 爬取店铺
    crawlStore store, fullCrawl, ->
    # 查询网址配置表获取当前爬虫的爬取的店铺ID 区间，并更新获取时间
      db.query "update ecm_crawl_config set now_id = #{store['store_id']}, last_update = '#{new Date()}' where ip = '#{ip}'; select ip, start_id, end_id, now_id from ecm_crawl_config where ip = '#{ip}';", (err, results) ->
        # 如果使用淘宝API爬取
        if needCrawlItemsViaApi
          console.log "id:#{store['store_id']} #{store['store_name']} access_token: #{store['access_token']}"
          # 调用crawlItemsInStore ，传入店铺id ，access_token（授权登录换取）
          crawlItemsInStore store['store_id'], store['access_token'], ->
            
            buildOuterIid store['store_id'], ->
              resetNowIdIfNecessary results[1][0]
              # 释放连接
              pool.release poolRef
        else
          # 更新 last_update 日期
          db.query "update ecm_crawl_config set last_update = '#{new Date()}'", ->
            # 释放连接
            pool.release poolRef

# 先执行查询获取爬取任务队列 stores
db.query "select s.*,v.resweb_http from ecm_store s left join ecm_member_auth a on s.im_ww = a.vendor_user_nick and a.state = 1 left join ecm_store_resweb v on s.store_id = v.ecm_store_id where s.state = 1 and s.auto_sync != 1 and s.store_id > (select now_id from ecm_crawl_config where ip = '#{ip}') and s.store_id <= (select end_id from ecm_crawl_config where ip = '#{ip}') order by s.store_id", (err, unfetchedStores) ->
  if err then throw err
  # 任务队列 stores
  stores = unfetchedStores
  # 获取代理
  getIPProxy()
  # 执行爬虫
  setTimeout ->
    # 在日志中输出
    console.log "There are total #{stores.length} stores need to be fetched."
    # 执行crawl 爬取stores中的店铺
    crawl store for store in stores
  , 5000                        # 延迟5秒开始爬取，确保首次获取ip代理操作已经完成
