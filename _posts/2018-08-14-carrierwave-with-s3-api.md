---
layout:       post
title:        Ruby on Rails文件存储整合S3 API
subtitle:     存储对应用透明，存储升级扩容更灵活
date:         2018-08-14 21:36:25 +0800
author:       Archfish
header-img:   "img/s3_bucket.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Ceph
  - Ruby
  - Rails
  - S3
---

在项目初期我们将一台服务器插满硬盘并提供NFS服务挂载到各业务服务器上。业务产生的文件分为两类，一类是涉及隐私的敏感文件，另一类是可公开访问的普通文件。普通文件需要对接CDN以降低服务器带宽压力。敏感文件只能在相应业务使用到时才能访问，通常是先加载到内存然后再嵌入页面或Base64编码后通过JSON返回给前端。

在业务系统中使用[CarrierWave][1]作为文件上传管理组件，部分图片相关业务需要生成缩略图或保存多版本文件。

## files

对外URL只能处理可公开访问的文件，对于隐私文件只能使用文件操作读取到内存。下面是uploader封装统一URL的例子，其他的uploader继承该class即可，使用时直接使用`external_url`。

```ruby
class BaseUploader < CarrierWave::Uploader::Base
  include CarrierWave::MiniMagick
  storage :file

  def external_url
    return if self.blank?

    return if private_file?

    # 使用最后更新时间作为CDN自动过期方案
    s = (self.model.try(:updated_at) || self.model.try(:created_at) || Time.current).tv_sec
    s = "?t=#{s}"

    wrap_cdn(url.sub(File.expand_path(Rails.root), '') + s)
  end

  def wrap_cdn(file_path)
    if fit_cdn_condition?
      File.join(cdn_domain, file_path)
    else
      File.join(backend_domain, file_path)
    end
  end
end
```

## aws

我们是托管服务器，综合对比了几款S3兼容存储软件后决定选择Ceph作为存储服务，考虑到后期可能需要块存储Ceph是个不错的选择。CarrierWave配合[carrierwave-aws][2]可以很方便使用[aws-sdk-ruby][3],假设RGW服务地址为`http://ceph:10086`则可以通过下面的方式配置s3

```ruby
# config/initializers/carrierwave.rb

CarrierWave.configure do |config|
  config.storage    = :aws
  config.aws_bucket = :mybucket
  config.aws_acl    = 'public-read'

  # 该参数用于设置图片访问域名
  # config.asset_host = File.join(endpoint, bucket)

  # 隐私文件开放时间，过期则返回403
  config.aws_authenticated_url_expiration = 30.minute.to_i

  config.aws_attributes = {
    cache_control: 'max-age=604800'
  }

  config.aws_credentials = {
    access_key_id:     :access_key,
    secret_access_key: :secret_key,
    force_path_style:  true,
    endpoint:          'http://ceph:10086',
    region:            'us-east-1',
    stub_responses:    Rails.env.test? # Optional, avoid hitting S3 actual during tests
  }
end
```

```ruby
# base_uploader.rb

class BaseUploader < CarrierWave::Uploader::Base
  include CarrierWave::MiniMagick
  storage :aws

  # 获取图片外部访问地址，有CDN可用时使用CDN
  def external_url
    return if self.blank?

    # 私有文件会带上一些鉴权参数，不能对其进行修改
    return url unless public_file?

    s = (self.model.try(:updated_at) || self.model.try(:created_at) || Time.current).tv_sec
    s = "?t=#{s}"

    url_ = self.url
    # 自定义 asset_host 时不做替换
    if self.asset_host.blank?
      url_ = url_.sub(backend_domain, cdn_domain)
    end
    url_ + s
  end

  # 根据文件类型设置文件的访问权限
  # CarrierWave::Uploader::Base::ACCEPTED_ACL
  def aws_acl
    public_file? ? 'public-read' : 'private'
  end

  # 用于处理不同时期不同存放路径问题，无此需求忽略这个方法
  def dir_exists?(dir)
    # 检查S3存储目录是否存在，其他存储可能不适用
    # NOTE S3存储中，如果目录没有文件则父目录也不存在
    if self._storage == CarrierWave::Storage::AWS
      bucket = Aws::S3::Bucket.new(self.aws_bucket, self.aws_credentials)
      bucket.objects(prefix: dir).limit(1).any?
    else
      Dir.exist?(dir)
    end
  end
end
```

经过上面的修改之后相同的接口就能直接适配S3存储，同时隐私文件夹通过设置合理的expires即可限制资源的访问。

# 生产环境

通过Nginx将内部服务暴露到公网中，这时你会遇到一个[bug][4]，还有这个[bug][5]。所以在业务需要处理1XX状态码时不宜使用nginx作为反向代理。

整个流程搞定以后我也进行了反思：

- 对于文件上传，通过nginx会增加不必要的代理层；
- 在这个需求中我只希望通过外网可以访问文件而不需要外网（通过Nginx代理）直接上传文件；
- 文件上传使用内部网络（IP+端口方式）可以减少DNS环节，虽然可以设置内部DNS为内部地址，提高稳定性；

于是改变思路，默认endpoint还是内网的IP+PORT方式，在获取URL时，创建一个新的client用于对文件URL进行签名，最终的代码如下：

```ruby
# config/initializers/carrierwave.rb

CarrierWave.configure do |config|

  ...

  # 设置CDN域名+bucket名
  config.asset_host = File.join(CDN_DOMAIN, bucket)

  ...
end
```

```ruby
# base_uploader.rb

# 获取图片外部访问地址，有CDN可用时使用CDN
def external_url
  return if self.blank?

  # 私有文件会带上一些鉴权参数，不能对其进行修改
  return authenticated_url unless public_file?

  s = (self.model.try(:updated_at) || self.model.try(:created_at) || Time.current).tv_sec
  s = "?t=#{s}"

  url_ = self.url
  # 自定义 asset_host 时不做替换
  if self.asset_host.blank?
    url_ = url_.sub(backend_domain, cdn_domain)
  end
  url_ + s
end

# 用于修改aws endpoint到图片服务器
def authenticated_url
  # 不能修改 self.aws_credentials 的内容，否则会影响之后的文件上传操作
  options = self.aws_credentials.merge(endpoint: APP_CONFIG['ceph_image_gateway'])
  # 新建一个bucket客户端，用于访问对象
  bucket = Aws::S3::Bucket.new(self.aws_bucket, options)
  # 预签名URL，加上验签信息
  bucket.object(path).presigned_url(:get, self.file.aws_options.expiration_options)
end
```

# CORS

为了正常嵌入其它域名的页面中，可能需要配置bucket允许跨域请求，这里提供一个[模板][7]，在bucket上配置以后就不需要在nginx上配置了，否则可能会出现[错误][8]。在给配置方案时，运维同学理解出现偏差，除了对S3 bucket进行操作，还同时配置了nginx，导致我花了一个小时去排查这个问题。

```xml
<!-- cors.xml -->
<CORSConfiguration>
 <CORSRule>
   <AllowedOrigin>*</AllowedOrigin>
   <AllowedMethod>GET</AllowedMethod>
 </CORSRule>
</CORSConfiguration>
```

```shell
s3cmd setcors cors.xml s3://reocar/
```

# 附录

附上我排查bug的流程：

- 打开ceph rgw的`debug 20`模式；
- 关闭osd日志（这里有很多集群消息）；
- 使用s3cmd工具上传文件并将日志拷贝出来（s3cmd不使用100状态码，所以经过nginx以后还是能正常上传文件）；
- 使用s3 ruby sdk上传文件，并将日志拷贝出来
- 比对两次日志即可发现sdk里使用的是100状态实现首次请求不带任何body只验证权限和路径等信息，[参考S3实现][6]

```logger
# s3cmd

2018-08-20 11:43:05.426 7f789febc700 20 CONTENT_LENGTH=392424
2018-08-20 11:43:05.426 7f789febc700 20 CONTENT_TYPE=image/jpeg
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_ACCEPT_ENCODING=identity
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_AUTHORIZATION=AWS4-HMAC-SHA256 Credential=QZPWZQQ4PCUVXKZA1CK4/20180820/us-east-1/s3/aws4_request,SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date;x-amz-meta-s3cmd-attrs;x-amz-storage-class,Signature=7dad3193636d4d3c66b2a06877c135d50834fbb9f7a94c26c3c8a198cd81a14e
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_HOST=my.local.lan
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_VERSION=1.1
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_AMZ_CONTENT_SHA256=867a5e890d8e8b156d16d33d8bbc135fd4d3b8f73844fb2d2e69df668fc4447c
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_AMZ_DATE=20180820T034305Z
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_AMZ_META_S3CMD_ATTRS=atime:1534736585/ctime:1532484245/gid:20/gname:staff/md5:cfef3b9dac46df5d717e32ca33d3e7da/mode:33188/mtime:1532412861/uid:501/uname:weihl
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_AMZ_STORAGE_CLASS=STANDARD
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_FORWARDED_BY=127.0.0.1:80
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_FORWARDED_FOR=127.0.0.1
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_FORWARDED_PROTO=http
2018-08-20 11:43:05.426 7f789febc700 20 HTTP_X_REAL_IP=127.0.0.1
2018-08-20 11:43:05.426 7f789febc700 20 REMOTE_ADDR=192.168.15.58
2018-08-20 11:43:05.426 7f789febc700 20 REQUEST_METHOD=PUT
2018-08-20 11:43:05.426 7f789febc700 20 REQUEST_URI=/reocar/reocar.jpg
2018-08-20 11:43:05.426 7f789febc700 20 SCRIPT_URI=/reocar/reocar.jpg
2018-08-20 11:43:05.426 7f789febc700 20 SERVER_PORT=7480
2018-08-20 11:43:05.426 7f789febc700  1 ====== starting new request req=0x7f789feb3830 =====
...
```

```logger
# ruby sdk

2018-08-20 11:45:14.781 7f789febc700 20 CONTENT_LENGTH=392424
2018-08-20 11:45:14.781 7f789febc700 20 CONTENT_TYPE=
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_ACCEPT=*/*
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_ACCEPT_ENCODING=
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_AUTHORIZATION=AWS4-HMAC-SHA256 Credential=QZPWZQQ4PCUVXKZA1CK4/20180820/us-east-1/s3/aws4_request, SignedHeaders=content-md5;expect;host;user-agent;x-amz-content-sha256;x-amz-date, Signature=6186f7dd9c9a33be40a91afd1ce0a9c4ce5cb8b830962764cebef6143d4913a3
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_CONTENT_MD5=z+87naxG311xfjLKM9Pn2g==
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_EXPECT=100-continue
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_HOST=my.local.lan
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_USER_AGENT=aws-sdk-ruby3/3.23.0 ruby/2.1.9 x86_64-darwin17.0 aws-sdk-s3/1.17.0
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_VERSION=1.1
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_AMZ_CONTENT_SHA256=867a5e890d8e8b156d16d33d8bbc135fd4d3b8f73844fb2d2e69df668fc4447c
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_AMZ_DATE=20180820T034514Z
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_FORWARDED_BY=127.0.0.1:80
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_FORWARDED_FOR=127.0.0.1
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_FORWARDED_PROTO=http
2018-08-20 11:45:14.781 7f789febc700 20 HTTP_X_REAL_IP=127.0.0.1
2018-08-20 11:45:14.781 7f789febc700 20 REMOTE_ADDR=192.168.15.58
2018-08-20 11:45:14.781 7f789febc700 20 REQUEST_METHOD=PUT
2018-08-20 11:45:14.781 7f789febc700 20 REQUEST_URI=/reocar/reocar.jpg
2018-08-20 11:45:14.781 7f789febc700 20 SCRIPT_URI=/reocar/reocar.jpg
2018-08-20 11:45:14.781 7f789febc700 20 SERVER_PORT=7480
2018-08-20 11:45:14.781 7f789febc700  1 ====== starting new request req=0x7f789feb3830 =====
...
```

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://github.com/carrierwaveuploader/carrierwave "CarrierWave"
[2]: https://github.com/sorentwo/carrierwave-aws "carrierwave-aws"
[3]: https://github.com/aws/aws-sdk-ruby "aws-sdk-ruby"
[4]: https://tracker.ceph.com/issues/23149 "Aws::S3::Errors::SignatureDoesNotMatch"
[5]: https://trac.nginx.org/nginx/ticket/1293 "nginx http proxy stops sending request data after first byte of server response is received"
[6]: https://docs.aws.amazon.com/zh_cn/AmazonS3/latest/API/RESTObjectPUT.html "PUT Object"
[7]: https://docs.aws.amazon.com/zh_cn/AmazonS3/latest/dev/cors.html "跨源资源共享 (CORS)"
[8]: https://github.com/aspnet/CORS/issues/129 "The 'Access-Control-Allow-Origin' header contains multiple values '*, *', but only one is allowed"
