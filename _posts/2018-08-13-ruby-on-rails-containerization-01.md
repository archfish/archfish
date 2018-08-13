---
layout:       post
title:        Ruby on Rails容器化实践（一）
subtitle:     多环境服务架构设计
date:         2018-08-13 21:46:18 +0800
author:       Archfish
header-img:   "portfolio/images/rails_containerization.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Ruby
  - Rails
  - Docker
  - Kubernetes
---

为了方便新功能的开发和对接Reocar的Staging环境从1个变成了8个，其中7个是用于新需求测试和第三方渠道对接，还有一个是预发布环境。

初代测试环境使用了基于KVM技术的虚拟机技术，对外需要占用一个公网IP。随着团队扩张，测试环境也跟着扩展到两个，这时公网IP的80端口已经被占用了，只能另外开端口进行服务。于是开启了测试环境的混沌时代，每增加一个环境就新增一组域名和端口，当增加到第三组环境时，已经没有人能记住所有的域名和端口。每组环境也由原来的1个服务增加到4个，混乱的域名和端口增加了团队沟通成本。

我决定对测试环境的服务架构进行重新设计。公网IP是个非常匮乏的资源，必须要好好利用起来，域名应当整齐划一降低记忆成本，响应全站HTTPS化号召重视数据安全。

# 整体结构

```
                                     Nginx
                   ____________________|_______________________
                   |                                          |
                Staging1               ...                 StagingN
    _______________|_____________              _______________|______________
    |        |        |         |              |         |        |         |
  Puma    nodemon  nodemon    Puma     ...    Puma    nodemon  nodemon     Puma
    |       |         |         |              |        |         |         |
Backend    Web  Mobile/WeChat  API          Backend    Web  Mobile/WeChat  API
|------------------------------------------------------------------------------|
|                               Docker Instance                                |
|------------------------------------------------------------------------------|
```

## Nginx

Nginx容器将80和443端口映射到主机上，同时负责卸载HTTPS后将流量转发到相应的容器中。HTTPS使用[Let's Encrypt][1]的ECC证书，并配置crontab每个星期检查是否需要延期。配置gzip压缩，节省机房上行流量。一个反向代理的示例如下所示，在编写中将相同配置抽取到单独的文件从而可以在不同配置中复用，其中如果使用了泛域名证书`conf.d/ssl.inc`可以放到nginx.conf中，每个server文件就不需要再引用该文件了。

```nginx
# backend1.lv3.lv2.lv1.conf

upstream s1_backend {
   server backend1.reocar.service:3000;
}

server{
  listen 80 default_server;
  listen 443 ssl http2 default_server;

  include conf.d/ssl.inc;

  server_name backend1.lv3.lv2.lv1;

  location / {
    include    conf.d/proxy_set_header.inc;

    proxy_pass http://s1_backend;
  }
}
```

```nginx
# conf.d/proxy_set_header.inc

proxy_read_timeout 300;
proxy_connect_timeout 300;
proxy_redirect     off;

proxy_set_header    X-Forwarded-By       $server_addr:$server_port;
proxy_set_header    X-Forwarded-For      $remote_addr;
proxy_set_header    X-Forwarded-Proto    $scheme;
proxy_set_header    Host                 $host;
proxy_set_header    X-Real-IP            $remote_addr;
```

```nginx
# conf.d/ssl.inc

ssl_certificate /path/to/ssl/name.cer;
ssl_certificate_key /path/to/ssl/name.key;
ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_dhparam /path/to/ssl/dhparam.pem; # openssl dhparam -out /path/to/dhparam.pem 4096
# ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  30m;
ssl_session_cache shared:SSL:8m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 100.100.2.138 100.100.2.136 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header X-Robots-Tag none;
```

使用反向代理理论上一个公网IP可以带无限多个域名，只要请求的时候使用了正确的域名即可。某些银行在支付时只能使用IP+端口的方式配置回调地址，Nginx同样可以处理这种问题。只要修改listen的端口为目标端口并将容器的相应接口映射到主机上，server_name配置为`_`代表其它server都没有匹配时使用当前配置，因为该端口具有明确目标，所以将proxy_pass指向正确的upstream即可。

## 统一域名

建议划一个专用的三级域名用于这些测试环境，命名按照`[类型][编号].三级域名.二级域名.顶级域名`的方式进行，这样就非常整洁了，在申请HTTPS正式时可以将该三级域名及其下的所有四级域名全部包含进去，只需要申请一个证书即可服务全部域名。

## 证书申请

泛域名解析只能使用DNS方式申请，这里我们选[acme.sh][2]。安装方式见项目主页，这里以阿里云DNS为例申请一个泛域名解析。

```shell
# cat ~/.acme.sh/account.conf

#LOG_FILE="/root/.acme.sh/acme.sh.log"
#LOG_LEVEL=1

#AUTO_UPGRADE="1"

#NO_TIMESTAMP=1

ACCOUNT_EMAIL='you@email.com'
SAVED_Ali_Key='LTAI*********Wb5'
SAVED_Ali_Secret='Ra8***************JsDoS'
USER_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
```

```shell
acme.sh --issue --dns dns_ali -d lv3.lv2.lv1 -d *.lv3.lv2.lv1 --ecc -k ec-384
```

执行完成后，工具会自动配置一个crontab任务，使用如下命令即可查看。

```log
# crontab -l
29 0 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null
```

接下来再将`~/.acme.sh/lv3.lv2.lv1_ecc/`中的证书软链到一个nginx能访问的目录中即可。

注：

- 敏感信息我都进行了处理，请按照实际情况修改
- 使用时请将`lv3.lv2.lv1`替换为你的目标域名

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://letsencrypt.org "Let's Encrypt - Free SSL/TLS Certificates"
[2]: https://github.com/Neilpang/acme.sh "An ACME Shell script"
