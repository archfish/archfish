---
layout:       post
title:        Rails(4.1)中的缓存管理
subtitle:     复杂业务场景下的缓存淘汰方案
date:         2018-08-12 13:12:26 +0800
author:       Archfish
header-img:   "img/caching_with_rails.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Rails
  - Redis
  - Ruby
---

在rails中我们常用的有[Rails#cache][1]和[IdentityCache][2]这两种cache方式。在长期实践中发现了不少问题，于是我们研发了一个新的缓存组件[CacheWorker][5]。下面对这些组件进行大致介绍：

## IdentityCache

这是一种`ActiveRecord Caching`组件，提供了若干读方法，通过`after_commit`回调对缓存进行淘汰，我们业务系统中使用的是Redis作为后端默认情况下该缓存无过期时间。
在实际使用中，比直接查询数据库大概快30%左右。如果数据没有通过统一rails应用进行更新，则会导致脏数据，所以这种方式在后期微服务拆分中会带来很大的问题。表的一行记录可能会很大，当使用的热数据很多时，对redis是个不小的压力，所以在redis中存放这种缓存是否真的划算我表示怀疑。

## Rails Cache

这种缓存方式支持更灵活的缓存key定义，前期在系统中大量使用。根据查询结果中的最新更新时间作为cache key的条件之一实现在这部分数据发生变化时自动使用新的cache key，从而实现缓存的淘汰。就算不是通过同一Rails应用修改数据也能做到最大程度降低脏缓存出现的几率。

```ruby
records     = Table.where(aa: :bb)
last_update = records.maximum(:updated_at)
count       = records.size
cache_key   = "#{prefix}:using_for:#{count}:#{last_update.to_i}"
cache_opts  = {
  expires_in: 15.minutes
}
result =  Rails.cache.fetch(cache_key, cache_opts) do
  logic
  ...
end
```

这种方式有几个问题：

- 当records的查询条件发生变化时，可能会导致在小于`max(update_at)`的范围内增加或减少记录从而导致缓存变脏。

  要解决这种问题，只能在算法发生变化时主动删除相关缓存，但是靠人为去记忆哪些数据需要删除就很困难了，大项目中有谁敢打包票对每一处细节都非常熟悉呢？这时只能尽量降低缓存的生存时间，从而降低脏缓存存在的时间，但是某些情况下脏缓存会带来灾难性的后果。

- 为了确定数据是否有发生变化额外增加两次SQL查询。

  随着数据库中的数据越来越多，这两个SQL操作的成本就越不能忽略。

- 缓存的量达到一点程度时，主动清空缓存变成了负担。

  在使用中我们发现，当key总数在百万级别时，执行`Rails.cache.clear`几乎不可能成功，表现为执行了很长时间以后就会报`systemstackerror`错误。这是因为一次性从redis里拉回太多数据导致的，对数据分批后问题解决。

  ```ruby
  # 分批清理Rails.cache缓存
  # NOTE Rails.cache 键值达到一定程度时会出现 `systemstackerror`
  #
  # options
  #   match String  匹配字符串
  #   count Integer 每批清理数目
  def wipe_all_cache!(match: '*', count: 10240)
    rails_options = Rails.cache.options
    redis = Redis.new(rails_options)
    match_str = "#{rails_options[:namespace]}:#{match}"

    cursor = '0'
    cleared_count = 0
    loop do
      cursor, keys = redis.scan(cursor, match: match_str, count: count)

      (cursor == '0' ? break : next) if keys.blank?

      redis.del(*keys)
      cleared_count += keys.count
    end

    cleared_count
  end
  ```

## Cache Worker

该组件由缓存注册和事件处理两个部分组成。在初期版本中，我尝试在淘汰逻辑中删除redis中对应的key，但是[Redis不支持设置Set中的key的过期时间][4]，这就会导致长时间运行下某些Set中的key总数非常大，进行删除时会导致redis处理超时。后来通过设置比较短的TTL，通过修改model对应的一串key实现缓存淘汰。同时增加一个redis队列用于顺序处理过期事件。数据结构如下所示：

```ruby
{
  model1_name: SecureRandom.urlsafe_base64(5),
  model2_name: SecureRandom.urlsafe_base64(5),
  model3_name: SecureRandom.urlsafe_base64(5)
}

queue: [:event1, :event2, :event3, :event4]
```

### 缓存注册

- 相关Model需注册相关事件回调，在回调中发布相关事件

  在所有`after_commit`之后执行`publish_event`发布默认数据变更事件，其中还有该次提交所涉及的变化，在`publish_event`可以对缓存过期的条件进行自定义规则，从而实现更细致的缓存控制。

  ```ruby
  def self.included(base)
    base.extend ClassMethods
    base.class_eval do
      after_commit :publish_event
    end
  end

  private
  def publish_event
    event_type = case
    when transaction_include_any_action?([:create])
      'create'
    when transaction_include_any_action?([:update])
      'update'
    when transaction_include_any_action?([:destroy])
      'destroy'
    end

    payload = {
      event_type: event_type,
      changed_attributes: self.previous_changes.keys,
      class: self.class.name,
      primary_key: self.id
    }

    ActiveSupport::Notifications.instrument(self.class.event_name, payload)
  end
  ```

  这里可以更进一步，对于`update_all`和`delete_all`也增加了一个回调，这样就完成了所有数据变更操作都有发布信息。

  ```ruby
  # hack update_all 和 delete_all 同样发出消息
  module ::ActiveRecord
    class Relation
      alias_method :orig_update_all, :update_all
      alias_method :orig_delete_all, :delete_all

      def update_all(updates)
        result = orig_update_all(updates)
        if respond_to? :publish_event
          publish_event(__method__)
        end
        result
      end

      def delete_all(conditions = nil)
        result = orig_delete_all(conditions)
        if respond_to? :publish_event
          publish_event(__method__)
        end
        result
      end
    end
  end
  ```

- 缓存Key注册

  在Rails#cache的基础上去掉`updated_at`和`size`后通过将相关model的当前序列拼接到后面。

  ```ruby
  # options
  #   expires_in Integer second
  #   related_modules Array ActiveRecord class
  def cache(cache_key, options = {}, &block)
    if cache_key.blank? || Rails.env.test?
      return yield if block_given?
    end

    cache_options = (options || {}).slice(:expires_in, :compress, :race_condition_ttl)
    # 过期冗余，允许key在过期6秒内继续读取
    cache_options[:race_condition_ttl] ||= 6.seconds

    related_modules = Array(options[:related_modules] || [])
    # NOTE 默认有效期为3小时，键过期后会一直存在，只能依赖LRU清除，Redis须配置一个合适的Hz值
    if related_modules.blank? || cache_options[:expires_in].blank?
      cache_options[:expires_in] ||= 3.hours
    end

    cache_key = Reocar::CacheWorker.register_cache(cache_key, *related_modules)

    Rails.cache.fetch(cache_key, cache_options) do
      yield if block_given?
    end
  end

  def related_module_identity(module_names)
    module_names = wash(module_names)
    identity_hash = current_identity(module_names)

    identity_hash.each_pair.map do |k, v|
      "#{k}.#{v}"
    end.join(':').hexdigest
  end

  def update_module_identity!(module_names)
    module_names = wash(module_names)
    hash = current_identity(module_names)

    module_names.each do |k|
      cache_version = ''
      loop do
        cache_version = SecureRandom.urlsafe_base64(5)
        break if cache_version != (hash[k] || '')
      end
      hash[k] = cache_version
    end

    redis_client.mapped_hmset(self, hash)
  end

  def current_identity(module_names)
    module_names = wash(module_names)

    redis_client.mapped_hmget(self, *module_names)
  end

  def update_module_identity!(module_names)
    module_names = wash(module_names)
    hash = current_identity(module_names)

    module_names.each do |k|
      cache_version = ''
      loop do
        cache_version = SecureRandom.urlsafe_base64(5)
        break if cache_version != (hash[k] || '')
      end
      hash[k] = cache_version
    end

    redis_client.mapped_hmset(self, hash)
  end


  def wash(module_names)
    module_names = module_names.is_a?(Array) ? module_names : Array(module_names)
    module_names.map(&:to_s).sort
  end
  ```

  ```ruby
  # 用法
  cache_key = 'current_key_name'
  cached_data = cache(cache_key, related_modules: [Model1, Model2]) do
    logic
    ...
  end
  ```

### 事件处理

- 监听相关事件

  先注册事件监听，在`config/initializers`中增加`subscribe_notification.rb`文件，并增加以下内容：

  ```ruby
  ActiveSupport::Notifications.subscribe(/^#{Reocar::Publisher::COMMIT_EVENT_PREFIX}/) do |*args|
    Reocar::CacheWorker.push(*args)
  end
  ```

  这样我们就可以监听到model发出的消息了。

- 淘汰缓存

  监听到事件以后需要及时对缓存进行淘汰，由于我们还没迁移至[sidekiq][3]，所以决定启动一个专门处理该事件的工作线程。

  ```ruby
  module Reocar
    module CacheWorker
      def push(*args)
        event = ActiveSupport::Notifications::Event.new(*args)

        queue_push(event.payload[:class])
        if worker.stop? && worker.status != 'sleep'
          Thread.current[:cw_thread] = nil
          worker
        end
      end

      def worker
        Thread.current[:cw_thread] ||= Thread.new do
          while args = queue_pop
            wipe_cache(args)
          end
        end
      end

      def wipe_cache(module_name)
        return if module_name.blank?

        update_module_identity!(module_name)
      end
    end
  end
  ```

这个方案对缓存的管理是比较粗旷的，对redis操作频率不高但是内存消耗比精细管理要高一些。在使用中很容易就可以找出当前缓存的关联model，通过按model定义publish_event即可实现更精细的过期控制。上面给出的只是一个比较初级的版本，顺着这个思路应该可以实现更简易的缓存管理组件。

本文只在做数据库读写分离前适用，读写分离后缓存管理要复杂得多，这里不做讨论。

- - -

欢迎跟我交流 [Archfish][0]

[1]: https://guides.rubyonrails.org/caching_with_rails.html#low-level-caching "Rails#cache"
[2]: https://github.com/Shopify/identity_cache "IdentityCache"
[3]: https://github.com/mperham/sidekiq "sidekiq"
[4]: https://github.com/antirez/redis/issues/167 "Implement Expire on hash"
[5]: /2018/08/12/caching-with-rails "Cache Worker"
[0]: https://github.com/archfish/archfish "archfish blog"
