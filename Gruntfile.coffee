module.exports = (grunt) ->

  makeServerConfig = ({host, port, authKey}) ->
    auth:
      host: host
      port: port
      authKey: authKey
    src: './'
    dest: '/alidata/www/test2/node/51fetch_all/'
    exclusions: ['.DS_Store', 'node_modules', '.git', '.ftppass', 'sftpCache.json', 'config.json']
    serverSep: '/'
    concurrency: 4
    progress: true

  grunt.initConfig
    pkg: grunt.file.readJSON 'package.json'

    'sftp-deploy':
      jushita: makeServerConfig
        host: '121.196.142.10'
        port: 30002
        authKey: 'jushita'
      aliyun: makeServerConfig
        host: '112.124.54.224'
        port: 5151
        authKey: 'aliyun'
      wangzong: makeServerConfig
        host: '120.24.63.15'
        port: 22
        authKey: 'wangzong'
      test2: makeServerConfig
        host: '115.29.221.120'
        port: 22
        authKey: 'test2'
      test1: makeServerConfig
        host: '121.40.85.153'
        port: 22
        authKey: 'test1'

  grunt.loadNpmTasks 'grunt-sftp-deploy'

  grunt.registerTask 'dist', ['sftp-deploy:aliyun', 'sftp-deploy:jushita', 'sftp-deploy:test2', 'sftp-deploy:wangzong', 'sftp-deploy:test1']
