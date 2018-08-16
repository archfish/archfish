---
layout:       post
title:        Golang开发环境搭建（vs code）
subtitle:     带梯子和不带梯子两个版本
date:         2018-08-16 21:57:18 +0800
author:       Archfish
header-img:   "img/golang.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Golang
  - vs code
---

# 组织项目

许多从其它语言转到golang的可能都会有一个疑问：GOPATH是什么？官方的[wiki][1]是这样说的：

> The GOPATH environment variable specifies the location of your workspace.

即GOPATH指向一个工作区，可类比到Linux的文件系统，系统只能访问根(/)下的文件，而根之上是什么就不是系统管理的范围了。回到go语言里，GOPATH下的代码才能被go管理，在这个路径之上的源码一概不理会。

```
                                GOPATH
              ____________________|____________________
              |                   |                   |
             src                 bin                 pkg
        ______|_______        ____|____          _____|_____
        |     |      |        |       |          |         |
     GitHub Gopkg  Other        Tools           Platform Code
```

GOPATH的文件目录如上图所示，src下是以网站命名的文件夹，再往下才是项目目录。通过`go get`拉下来的源码就是按这样的层级结构存放的，我们自己的项目也建议保持这样的结构。

以我们公司来讲，我们通常将RoR项目存放在`~/Projects/`目录下，那有没有什么法子可以继续保持这样的组织方式还能满足go的组织风格呢？这时候就需要借助[软链][2]了，通过软链我们在`~/Projects/`下创建一个到GOPATH下相应项目的链接，这样就可以继续按照原来的风格管理go项目了。下图演示如何用vs code打开项目：

```log
$ echo $GOPATH

/Users/archfish/GoPath

$ ls -lh ~/Projects

lrwxr-xr-x   1 weihl  staff    51B 11 22  2017 gateway -> /Users/archfish/GoPath/src/github.com/fagongzi/gateway

$ cd ~/Projects/gateway && code .
```

# 配置开发工具

## 用梯子版

梯子有很多种，我这里拿其中一种已经没人使用的[梯子][3]做例子，其它类型梯子也可以按照这个思路操作。该梯子是使用的socket5协议进行通讯的，而shell中只能使用http或https协议，这里需要一个socket5->http/https的转换（可以试试这个[工具][4]我没用过供大家参考）。mac上可以使用一款叫[*X-NG][5]的客户端（>= 1.7），默认就可以转换为http协议，操作方式点击图标找到`Copy HTTP Proxy Shell Export Line`然后贴到shell中，然后通过shell启动vs code即可。以我的配置为例：

```shell
export http_proxy=http://0.0.0.0:1087;export https_proxy=http://0.0.0.0:1087;

cd ~/Projects/gateway && code .
```

- 打开vs code`扩展管理`搜索go，安装；
- 按下`shift + command + p`(Linux `ctrl + shift + p`)找到`Go: Install/Update Tools`；
- 等待安装完成即可

## 不用梯子版

- 打开vs code`扩展管理`搜索go，安装；
- 按下`shift + command + p`(Linux `ctrl + shift + p`)找到`Go: Install/Update Tools`；
- 打开[网站][6]，将上一步列出的包一个个按教程手动下载并安装

# 额外配置

## 空白处理

通过简单的配置可以让编辑器帮我们处理一些编辑任务：

- 文件最后保留一个空行
- 删除文件最后多余空行
- 清理每行结尾空格制表符等

```JSON
{
  "files.insertFinalNewline": true,
  "files.trimFinalNewlines": true,
  "files.trimTrailingWhitespace": true
}
```

## golang 1.9 alias支持

通过右键选择`Go to Definition`和`Peek Definition`在1.9版本后可能会无法正确跳转，这个其实是个[Bug][7]，如下配置即可：

```JSON
{
  "go.docsTool": "gogetdoc"
}
```

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://github.com/golang/go/wiki/SettingGOPATH "SettingGOPATH"
[2]: https://www.ibm.com/developerworks/cn/linux/l-cn-hardandsymb-links/index.html "理解 Linux 的硬链接与软链接"
[3]: https://github.com/shadowsocks/shadowsocks "Removed according to regulations."
[4]: https://github.com/nybuxtsui/goproxy "goproxy"
[5]: https://github.com/shadowsocks/ShadowsocksX-NG "ShadowsocksX-NG"
[6]: https://golangtc.com/download/package "离线pkg包"
[7]: https://github.com/Microsoft/vscode-go/issues/1261 "go-to-definition doesn't work in go 1.9 with type aliasing."
