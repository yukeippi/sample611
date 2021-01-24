# 前提条件
- rubyのインストールはrbenv + ruby-buildで行う。
- master.keyは本番サーバーに直接設置する。
- データベースのパスワードなどの設定はcredentials.yml.encに含める。
- Unicornはsystemdにてデーモン化する。
- Railsアプリのインストール先は「/var/rails/sample611/」
- デプロイはCapistranoで行う。

# 本番実行環境
- Ruby 2.7.2
- Rails 6.1.1
- Nginx + Unicorn
- Node.js 14
- Yarn
- PosgtreSQL

# 本番サーバー(Amazon Linux 2)の設定手順
1. ライブラリアップデート
```bash
$ sudo yum update -y
```

2. タイムゾーン、ロケール
```bash
$ sudo timedatectl set-timezone Asia/Tokyo
$ sudo localectl set-locale LANG=ja_JP.UTF-8
```

3. NTP
```bash
$ yum info chrony
$ chronyc sources -v
```

4. 標準パッケージインストール
```bash
$ sudo yum -y install gcc-c++ glibc-headers openssl-devel readline libyaml-devel readline-devel zlib zlib-devel libffi-devel libxml2 libxslt libxml2-devel libxslt-devel git
```

5. データベースモジュールのインストール
- PostgreSQLの場合
```bash
$ sudo yum -y install postgresql-devel
```

- MySQLの場合
```bash
$ sudo yum -y install mysql-devel
```

6. Rubyのインストール

rbenvのインストール
```bash
$ git clone https://github.com/sstephenson/rbenv.git ~/.rbenv
$ echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
$ echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
$ source ~/.bash_profile
$ rbenv -v
```

ruby-buildのインストール
```bash
$ git clone git://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
$ cd ~/.rbenv/plugins/ruby-build
$ sudo ./install.sh
$ rbenv install -l
```

Rubyのインストール
```bash
$ rbenv install 2.7.2
$ rbenv global 2.7.2
```

7. node.jsのインストール
```bash
$ curl -sL https://rpm.nodesource.com/setup_14.x | sudo bash -
$ sudo yum install -y nodejs
$ sudo npm install -g n
$ sudo n stable
$ sudo ln -snf /usr/local/bin/node /usr/bin/node
```

8. yarnのインストール
```bash
$ curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo | sudo tee /etc/yum.repos.d/yarn.repo
$ sudo yum install yarn -y
```

9. Railsのインストール
```bash
$ cd ~
$ mkdir rails
$ cd rails
$ bundle init
$ vim Gemfile
(gem "rails", "6.1.1"に書き換え、コメントアウト解除）

$ bundle install
$ bundle exec rails -v
（インストールされたことを確認）

$ cd ..
$ rm -rf rails
```

10. データベース作成

- RDSにてデータベースを作成し、ユーザー名、パスワード、データベースエンドポイントの取得
- セキュリティグループでウェブサーバーのセキュリティグループのアクセス許可を設定

11. データベースの設定

credentials.yml.encにデータベース設定をセットする。
```bash
$ EDITOR="vim" bin/rails credentials:edit
```

下記を追記する。
```yaml
db:
  username: (username)
  password: (password)
  host: (database endpoint)
```

config/database.ymlを編集。
```yaml
production:
  <<: *default
  database: sample611_production
  username: <%= Rails.application.credentials.db[:username] %>
  password: <%= Rails.application.credentials.db[:password] %>
  host:     <%= Rails.application.credentials.db[:host] %>
  port:     5432（MySQLの場合は3306）
```

12. デプロイ先設定

Railsアプリの設置場所を「/var/rails」とする。Railsアプリの実行はrootではなく、ec2-userで行うので、このディレクトリの所有者をec2-userにする。
```bash
$ cd /var/
$ sudo mkdir rails
$ sudo chown ec2-user:ec2-user rails
```

13. デプロイ準備

デプロイ設定を行う。
```bash
$ vim config/deploy.rb
（ここのコードの通り、編集）
$ vim config/deploy/production.rb
（ここのコードの通り、編集）
```

デプロイチェックを実施。
```bash
$ bundle exec cap production deploy:check

00:02 deploy:check:make_linked_dirs
      01 mkdir -p /var/rails/sample611/shared/config
    ✔ 01 ec2-user@52.195.2.51 0.078s
00:02 deploy:check:linked_files
      ERROR linked file /var/rails/sample611/shared/config/master.key does not exist on 52.195.2.51
```
ここで失敗。エラーは「master.key」がないことが原因。

```bash
$ cd /var/rails/sample611/shared/config/
$ touch master.key
$ vim master.key
（master.keyを貼り付け）
```

再度デプロイチェック

```bash
$ bundle exec cap production deploy:check
```
成功するはず。

14. デプロイ

まずデプロイしてみる。
```bash
$ bundle exec cap production deploy
```

ここで失敗。db:migrateをしようとしてデータベースがないことが原因。
本番サーバーからデータベースの作成を作成する。

```bash
$ cd /var/rails/sample611/releases/(最新リリース)/
$ bundle exec rails db:create RAILS_ENV=production
```
データベースができるはず。

```bash
$ bundle exec cap production deploy
```
成功するはず。

15. Nginxのインストール

```bash
$ sudo amazon-linux-extras install nginx1 -y
```

nginxとRailsアプリの連携設定
```bash
$ sudo touch /etc/nginx/conf.d/myapp.conf
$ sudo vim /etc/nginx/conf.d/myapp.conf
```

```
upstream railsapp {
    server unix:///var/rails/sample611/shared/tmp/sockets/unicorn.sock fail_timeout=0;
}

server {
    listen 80;
    server_name myapp.jp;

    root /var/rails/sample611/current/public;

    try_files $uri/index.html $uri @railsapp;

    location @railsapp {
        proxy_pass http://railsapp;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $http_host;
        proxy_redirect off;
    }

    error_page 500 502 503 504 /500.html;
    client_max_body_size 4G;
    keepalive_timeout 10;
}
```

16. Unicornのサービス化
```bash
$ sudo vim /etc/systemd/system/unicorn.service
```

Unicornの実行ユーザーを「ec2-user」にすること。
```
[Unit]
Description=The Unicorn Process

[Service]
User=ec2-user
Type=simple
Environment="RAILS_ENV=production"
WorkingDirectory=/var/rails/sample611/current
PIDFile=/var/rails/sample611/shared/tmp/pids/unicorn.pid

ExecStart=/home/ec2-user/.rbenv/shims/bundle exec /var/rails/sample611/shared/bundle/ruby/2.7.0/bin/unicorn_rails -c /var/rails/sample611/current/config/unicorn/production.rb -D
ExecStop=/bin/kill -QUIT $MAINPID
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
```

unicorn.serviceに実行権限を付与。
```bash
$ sudo chmod +x /etc/systemd/system/unicorn.service
```

17. Unicorn, Nginxの起動

unicornの起動
```bash
$ sudo systemctl daemon-reload
$ sudo systemctl start unicorn
$ sudo systemctl status unicorn
```

unicornを再起動するには下記を実行
```
$ sudo systemctl restart unicorn
```

nginxの起動
```
$ sudo systemctl start nginx.service
```

unicorn, nginxの自動起動設定
```
$ sudo systemctl enable unicorn.service
$ sudo systemctl enable nginx.service
```
