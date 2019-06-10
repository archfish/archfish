---
layout:       post
title:        Rails use postgresql-adapter to compute postgis
subtitle:     老版本rails(4.1)项目的福音
date:         2019-04-14 00:01:01 +0800
author:       Archfish
header-mask:  0.1
multilingual: false
tags:
  - Rails
  - PostgreSQL
  - Postgis
---

rails中每种数据库都有自己的adapter，这些adapter负责处理数据库的各种数据类型，但是设计上无法自行增加新数据类型。使用postgis功能通常使用的是[active-record-postgis-adapter][1]，由于Reocar使用的功能仅仅是计算坐标点间的距离，增加这样一层适配器会导致应用结构变得复杂，同时也可能会引入[新的问题][2]。在实现现有功能的情况下尝试移除active-record-postgis-adapter。

## 最小需求

- 计算两点之间的距离
- 找出以某点P为圆心X为半径所包含的所有点
- 找出离P点最近的点

## 思路

- 使用PG的条件索引对longitude和latitude进行索引
- 通过裸SQL进行数据操作

## 代码

为了在项目中跟进数据结构变化，需要将schema dump改为structure dump

```ruby
# config/environments/[ENV].rb

Rails.application.configure do
  config.active_record.schema_format = :sql
end
```

rails4.1与新版本pg导出SQL会出现[参数异常][4]，重写该task

```ruby
# lib/tasks/database.rake

Rake::Task["db:structure:dump"].clear
namespace :db do
  namespace :structure do
    desc "Overriding the task db:structure:dump task to remove -i option from pg_dump to make postgres 9.5 compatible"
    task dump: [:environment, :load_config] do
      config = ActiveRecord::Base.configurations[Rails.env]
      set_psql_env(config)
      filename =  File.join(Rails.root, "db", "structure.sql")
      database = config["database"]
      command = "pg_dump -s -x -O -f #{Shellwords.escape(filename)} #{Shellwords.escape(database)}"
      raise 'Error dumping database' unless Kernel.system(command)

      File.open(filename, "a") { |f| f << "SET search_path TO #{ActiveRecord::Base.connection.schema_search_path};\n\n" }
      if ActiveRecord::Base.connection.supports_migrations?
        File.open(filename, "a") do |f|
          f.puts ActiveRecord::Base.connection.dump_schema_information
          f.print "\n"
        end
      end
      Rake::Task["db:structure:dump"].reenable
    end
  end

  def set_psql_env(configuration)
    ENV['PGHOST']     = configuration['host']          if configuration['host']
    ENV['PGPORT']     = configuration['port'].to_s     if configuration['port']
    ENV['PGPASSWORD'] = configuration['password'].to_s if configuration['password']
    ENV['PGUSER']     = configuration['username'].to_s if configuration['username']
  end
end
```

创建包含经纬度的表

```ruby
# db/migrate/201902260xxxxx_create_stores.rb

class CreateStores < ActiveRecord::Migration
  def change
    create_table :stores do |t|
      t.decimal :latitude, precision: 9, scale: 6
      t.decimal :longitude, precision: 9, scale: 6
      t.string :name

      t.timestamps
    end
  end
end
```

启用数据库插件需要特权，应用账号可能没有相关权限，请使用特权账号操作

```psql
\c shop_db
create extension postgis;
```

封装一些方法

```ruby
# app/models/store.rb

class Store < ActiveRecord::Base
  def self.mk_location
    %{
      ST_GeographyFromText(
        'SRID=4326;POINT(' || #{table_name.inspect}.longitude || ' ' || #{table_name.inspect}.latitude || ')'
      )
    }
  end

  def self.mk_point(latitude, longitude)
    %{ST_GeographyFromText('SRID=4326;POINT(%f %f)')} % [latitude, longitude]
  end
end
```

在经纬度上创建条件索引

```ruby
# db/migrate/20190227xxxxx_add_index_for_location.rb

class AddIndexForLocation < ActiveRecord::Migration
  def change
    execute %{
      create index index_on_stores_location ON stores using gist (
        #{Store.mk_location}
      )
    }
  end
end
```

提供相关scope

```ruby
# app/models/store.rb

class Store < ActiveRecord::Base
  scope :nearby, -> (latitude, longitude, distance_in_meters = 2000) {
    where(%{
      ST_DWithin(
        #{mk_location},
        #{mk_point(latitude, longitude)},
        %d
      )
    } % [distance_in_meters])
  }

  scope :nearby_ordered, -> (latitude, longitude, distance_in_meters = 2000) {
    select(%{
        #{table_name.inspect}.*, ST_Distance(
          #{mk_location}, #{mk_point(latitude, longitude)}
        ) as distance
      }
    ).nearby(latitude, longitude, distance_in_meters).reorder("distance asc")
  }

  # other code
end
```

## 总结

- 我个人来说不喜欢滥用gem，如果因为一个小功能引入了一个超复杂的gem，在后期维护中会带来各种各样的麻烦；
- 我大致测试了一下在POINT上创建索引和直接使用条件索引，性能差异不算太大，对于现有场景来说性能差异在可接受范围内；

## 参考

[PostGIS and Rails: A Simple Approach][3]

[1]: https://github.com/rgeo/activerecord-postgis-adapter "ActiveRecord connection adapter for PostGIS, based on postgresql and rgeo"
[2]: https://github.com/rgeo/activerecord-postgis-adapter/issues/296 "version 2.2.2 prepared_statements setting not take effect"
[3]: http://ngauthier.com/2013/08/postgis-and-rails-a-simple-approach.html "PostGIS and Rails: A Simple Approach"
[4]: https://stackoverflow.com/questions/35999906/pg-dump-invalid-option-i-when-migrating "“pg_dump: invalid option — i” when migrating"

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
