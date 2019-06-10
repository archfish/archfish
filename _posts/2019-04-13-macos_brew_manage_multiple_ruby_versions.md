---
layout:       post
title:        macOS使用brew安装用户级ruby
subtitle:     通过简单的脚本即可实现多版本管理
date:         2019-04-13 23:43:08 +0800
author:       Archfish
header-mask:  0.1
multilingual: false
tags:
  - macOS
  - brew
  - Ruby
---

系统自带了一个ruby，但是这个ruby是保存在系统库中的，如果需要安装gem则会提示无权限`You don't have write permissions for the /Library/Ruby/Gems/2.3 directory.`。那么rvm呢，这货在安装ruby-2.3版本的时候总会出现openssl问题。

所以使用brew来安装一个user级的ruby，并通过简单脚本实现ruby版本切换：

## 安装ruby2.3

```shell
brew install ruby@2.3
```

## 更新rubygem

```shell
gem update --system
```

## 配置环境变量

```shell
export RUBY_HOME=/usr/local/opt/ruby@2.3
export GEM_HOME=$RUBY_HOME/lib/ruby/gems/2.3.0
export GEM_PATH=$RUBY_HOME/lib/ruby/gems/2.3.0
# 记录没有ruby时的环境变量
export ORIG_PATH=$PATH
export PATH="$RUBY_HOME/bin:/usr/local/lib/ruby/gems/2.3.0/bin:$ORIG_PATH"
```

## 封装并提供切换功能

```shell
export ORIG_PATH=$PATH

function ruby_use
{
    if [ "$1" = '' ]
    then
        export RUBY_MAIN_VERSION='2.3'
    else
        export RUBY_MAIN_VERSION=$1
    fi

    export RUBY_HOME="/usr/local/opt/ruby@${RUBY_MAIN_VERSION}"
    export GEM_HOME="${RUBY_HOME}/lib/ruby/gems/${RUBY_MAIN_VERSION}.0"
    export GEM_PATH="${RUBY_HOME}/lib/ruby/gems/${RUBY_MAIN_VERSION}.0"
    export PATH="${RUBY_HOME}/bin:/usr/local/lib/ruby/gems/${RUBY_MAIN_VERSION}.0/bin:$ORIG_PATH"
}

ruby_use
```

在需要切换ruby版本时在相应终端使用`ruby_use 版本`即可.

## 已知问题

- 不会自动在命令前加`bundle exec`, 解决办法：创建相关命令的alias。不推荐这样做`alias rails='bundle exec rails'`，会导致`rails new`时报找不到Gemfile错误。
- 暂不支持小版本控制
- 每次切换ruby版本只会对当前终端有效（或许这是feature...

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
