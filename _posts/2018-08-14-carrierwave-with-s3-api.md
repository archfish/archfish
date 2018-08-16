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

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://github.com/carrierwaveuploader/carrierwave "CarrierWave"
[2]: https://github.com/sorentwo/carrierwave-aws "carrierwave-aws"
[3]: https://github.com/aws/aws-sdk-ruby "aws-sdk-ruby"
