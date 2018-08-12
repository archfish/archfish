---
layout:       post
title:        Rails日志组件封装
subtitle:     基于Ruby logger二次封装
date:         2018-08-12 22:08:06 +0800
author:       Archfish
header-img:   "img/rails_logger_wrap.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Ruby
  - Rails
  - Logger
---

在原始的单体应用中，日志通常直接输出到文件，然后由crontab中的定时任务做日志切分。再进一步，可能会有[ELK][1]系统收集分析。ELK只能对格式化的日志进行处理，对于无规则的日志只能作为字符串处理。Rails默认日志并不够简洁，对ELK来说处理难度略大。

# 结构

日志主要处理“谁在什么时间做了什么事情”的问题，下面就按这个思维来分析到底要怎么设计日志格式。

## 谁

- 服务组件可能会有很多，而不同组件格式可能也不一样，那首先得记录日志工具的名字和版本；
- 相同的日志组件可能会根据业务的不同而分为不同组别；
- 服务一般多进程运行的，那进程号肯定是需要的；
- 公司达到一定规模以后，单机部署已经不能满足处理能力需求，这样就需要知道是哪台机器输出的日志；
- 如果是分布式环境还需要知道当前在处理的是哪个请求，所以需要记录traceID；

## 时间

时间主要是格式和精度问题，这里我们选RFC3339格式(`%Y%m%dT%H:%M:%S.%L%z`)，即日前与时间之间以T相连，精度到毫秒，带时区。带时区是防止运维失误导致某些机器系统时区与本地时区不符。

## 事情

即日志的主体，可能是请求信息、异常回溯信息或其他信息

# Show me the code!

## API

操作接口与默认保持一致，重新定义了参数的含义，`progname -> title`用于定义日志分组，方便对某一类日志进行统一分析。真实的日志内容通过block传入，从而降低非打印级别日志操作消耗。

- def debug(title = nil){ body }
- def info(title = nil){ body }
- def warn(title = nil){ body }
- def error(title = nil){ body }
- def fatal(title = nil){ body }

重写初始化方法，在开发环境和Test环境中输出一份默认格式的日志到终端便于调试。核心为`ActiveSupport::Logger.broadcast`方法的使用，对此实现有迷惑的可以看看这个函数的实现。但是这样做以后赋值给`Rails.logger`时，终端会输出两条重复日志，暂时无解（可以在给全局logger赋值的对象控制不进行broadcast，但是这样代码太丑了）。

```ruby
def initialize(*args)
  super
  @formatter = Formatter.new

  # NOTE 开发环境如果输出到文件则需要输出一份到终端，默认忽略设置格式
  if (Rails.env.development? || Rails.env.test?) && @logdev.dev.is_a?(File)
    stdout_logger = ::ActiveSupport::Logger.new(STDOUT)
    stdout_logger.formatter = SimpleFormatter.new
    self.extend(ActiveSupport::Logger.broadcast(stdout_logger))
  end

  @level = self.class.log_level
end
```

## Formatter

为了实现前面描述的日志格式，需要对Formatter进行定制。顺便在定制时对一些常见类型进行默认处理，比如倾印`StandardError`时希望只输出业务代码的backtrace，倾印`request`时只要请求路径和参数信息等。

```ruby
class Formatter < ::Logger::Formatter
  def initialize
    @datetime_format = '%Y%m%dT%H:%M:%S.%L%z'
  end

  def call(severity, timestamp, progname, msg)
    title, body = '', ''
    case msg
    when ::StandardError
      title = msg.message
      body = BacktraceCleaner.clean(msg.backtrace) if msg.backtrace
    when ::ActionDispatch::Request
      title = msg.path
      body = msg.params
    when ::Entity::Message
      title = msg.title
      body = msg.body
    else
      title = msg
    end
    "|#{severity}|#{format_datetime(timestamp)}|#{hostname}|#{logger_name}|v#{VERSION}|#{progname}|#{traceid}|###+#{title.inspect}-###|###+#{body.inspect}-###|\n"
  end

  def hostname
    @hostname ||= Socket.gethostname
  end

  def logger_name
    @logger_name ||= self.class.name
  end

  def traceid
    ::RequestStore.store[:traceid]
  end
end
```

此时为了让输出终端的日志可以更友好一些，希望能对日志进行上色。这里只实现三种颜色

```ruby
# 为输出添加颜色
class SimpleFormatter < ::Logger::Formatter
  # This method is invoked when a log event occurs
  def call(severity, timestamp, progname, msg)
    wrap(severity, msg, progname)
  end

  def wrap(severity, msg, progname)
    color = case severity.to_s.downcase
    when 'warn', 'unknown'
      33 # YELLOW
    when 'error', 'fatal'
      31 # RED
    else
      32 # GREEN
    end

    message = case msg
    when ::String
      msg
    when ::StandardError
      "#{msg.message}: #{(msg.backtrace || []).join("\n")}"
    else
      msg.inspect
    end

    "\e\[#{color};1m#{progname} #{message}\e\[0m\n"
  end
end
```

# 总结

到此，我们的日志模块就设计好了。title和body部分除了使用竖线分割外，为了正确切割出实际内容增加了额外标记`##+`和`-##`，这样logstash在切分时就不会出错了。
如果需要对日志格式进行调整，只需要升级`VERSION`编号即可，理论上通过对logstash的规则进行定制，多版本同时存在应该是没什么问题的。

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://www.elastic.co/elk-stack "ELK"
