---
layout:       post
title:        Ruby on Rails容器化实践（二点一）
subtitle:     适用于编译时有大量依赖的情况，基于Debian
date:         2019-01-10 15:55:16 +0800
author:       Archfish
header-img:   "img/make-docker-image.jpg"
header-mask:  0.1
multilingual: false
tags:
  - Ruby
  - Rails
  - Docker
  - Kubernetes
---
这是[Ruby on Rails容器化实践（二） - Archfish \| Blog](https://archfish.github.io/2018/08/20/ruby-on-rails-containerization-02/)的简化版。

## 大致流程

### 确定程序运行依赖

从正常跑的环境找一个服务进程，获取其PID后，获取需要依赖的库，并记录下来。以下流程以MacOS环境来举例（懒癌晚期），在Linux环境中依赖为`.so`。

```log
➜  ~ ps aux | grep rails
weihl            99276   0.0  0.0  4333252    340 s002  S+   Tue05PM   0:00.45 /Users/weihl/.rvm/rubies/ruby-2.1.9/bin/ruby bin/rails c

➜  ~ lsof -p 99276
COMMAND   PID  USER   FD   TYPE             DEVICE  SIZE/OFF       NODE NAME
ruby    99276 weihl  txt    REG                1,4      8960 4303138723 /Users/weihl/.rvm/rubies/ruby-2.1.9/bin/ruby
ruby    99276 weihl  txt    REG                1,4   2910948 4303138725 /Users/weihl/.rvm/rubies/ruby-2.1.9/lib/libruby.2.1.0.dylib
ruby    99276 weihl  txt    REG                1,4    422620 4303467382 /usr/local/Cellar/gmp/6.1.2_2/lib/libgmp.10.dylib
```

从结果可以得到当前运行除了Ruby自身运行库外还依赖`gmp`包，那么运行环境就需要包含`gmp`，版本也要一致。

这种方式得到的依赖是当前已经在使用的，还有一些是动态加载的，比如字体，图片处理（imagemagick）等，需要慢慢完善。如果能直接用`ldd`对应用找依赖就更好啦。

### 确定程序编译期依赖

这个直接问研发最快啦。比如我们应用就依赖开发工具包（debian: build-essential），libpq-dev，git，还有一大堆的gems。

### 发布阶段

利用包含编译期依赖的镜像进行打包，完成后将最终文件拷贝到由运行依赖的镜像中并提交到内部仓库。

## Dockerfile实现

### base_image

```dockerfile
# dockerfiles/base_image
FROM ruby:2.3-slim-stretch
ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    LANGUAGE=en_US:en

RUN apt update -y \
    && apt install --no-install-recommends -y libpq5 wget curl vim gnupg2 libxrender1 \
    && apt install --no-install-recommends -y file tzdata imagemagick gsfonts ttf-wqy-zenhei \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && apt clean

CMD [ "irb" ]
```

```shell
docker build -t ruby_base_image -f ./dockerfiles/base_image .
```

### builder_image

```dockerfile
# dockerfiles/builder_image
FROM ruby_base_image

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test

RUN apt update \
    && apt install -y build-essential libpq-dev \
    && apt install -y git \
    && apt clean

ADD ssh /root/.ssh

RUN chmod 700 /root/.ssh \
    && chmod 600 /root/.ssh/id_rsa* \
    && ssh-keyscan my.gitlab.service.com > ~/.ssh/known_hosts

WORKDIR /opt/my_apps

# 以下两个步骤缓存gems，那编译期只需要增量更新即可，定期更新该镜像
ADD Gemfile* ./

RUN bundle config --global frozen 1 \
    && bundle install -j4 --retry 3 \
    && rm -rf Gemfile*

CMD [ "irb" ]
```

```shell
docker build -t ruby_builder_image -f ./dockerfiles/builder_image .
```

### release_image

```dockerfile
# dockerfiles/release_image
FROM ruby_builder_image as Builder

ENV BUNDLE_WITHOUT=development:test

WORKDIR /opt/my_apps

RUN mkdir -p tmp/pids tmp/sockets \
    && bundle config --global frozen 1 \
    && bundle install -j4 --retry 3 \
    && bundle exec rake assets:clean[0] \
    && bundle exec rake assets:precompile \
    && bundle exec rake log:clear

FROM ruby_base_image

RUN addgroup --gid 6666 my_app_group \
    && adduser --uid 6666 --gid 6666 --disabled-password --gecos "Application" my_app_user

USER my_app_user

COPY --from=Builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=Builder --chown=my_app_user:my_app_group /opt/my_apps /opt/my_apps

ENV RAILS_LOG_TO_STDOUT=true

WORKDIR /opt/my_apps

EXPOSE 8080

ENTRYPOINT ["/bin/sh", "./entrypoint.sh"]
CMD [ "server" ]
```

```shell
docker build -t ruby_release_image -f ./dockerfiles/release_image .
```

## 协调全部流程

通过编写Makefile将以上脚本全部组织起来，部分参数抽取为参数传入。

```makefile
NAME              = $(shell basename -s . `git rev-parse --show-toplevel`)
GIT_COMMIT			  = $(shell git rev-parse --short HEAD)
GIT_BRANCH			  = $(shell git rev-parse --abbrev-ref HEAD)
DOCKER_BASE_NAME	= reocar-ruby-2.3:stretch
DOCKER_BUILDER_NAME	= reocar-ruby-2.3:builder
APP_ROOT			    = /opt/$(NAME)
CLEAN_IMAGES		  :=
BUILD_TAG			    := $(tag)
BUNDLE_WITHOUT		:= "development:test"


# check if base images exist

ifeq ("$(shell docker images -q $(DOCKER_BASE_NAME) 2> /dev/null)","")
	BUILD_BASE_IMAGE	= docker build -t $(DOCKER_BASE_NAME) -f ./dockerfiles/base_image .
else
	CLEAN_IMAGES		:= $(CLEAN_IMAGES) $(DOCKER_BASE_NAME)
	BUILD_BASE_IMAGE	=
endif

# check if builder images exist

ifeq ("$(shell docker images -q $(DOCKER_BUILDER_NAME) 2> /dev/null)","")
	BUILD_BUILDER_IMAGE	= docker build --build-arg FROM_IMAGE="$(DOCKER_BASE_NAME)" \
							--build-arg APP_ROOT="$(APP_ROOT)" \
							--build-arg BUNDLE_WITHOUT=$(BUNDLE_WITHOUT) \
							-t $(DOCKER_BUILDER_NAME) \
							-f ./dockerfiles/builder_image .
else
	CLEAN_IMAGES		:= $(CLEAN_IMAGES) $(DOCKER_BUILDER_NAME)
	BUILD_BUILDER_IMAGE	=
endif

CLEAN_IMAGES	:= $(shell echo $(CLEAN_IMAGES) | xargs)

ifeq ("$(CLEAN_IMAGES)","")
	CLEAN_DOCKER_IMAGES	=
else
	CLEAN_DOCKER_IMAGES	= docker rmi $(CLEAN_IMAGES)
endif

ifeq ("$(BUILD_TAG)","")
	BUILD_TAG	:= $(shell date +%Y%m%d%H%M)
endif

.PHONY: docker base builder cpssh clean
.DEFAULT_GOAL := docker

docker: base builder; $(info ======== build $(NAME) release image:)
	docker build --build-arg RUNTIME_IMAGE="$(DOCKER_BASE_NAME)" \
				--build-arg BUILDER_IMAGE="$(DOCKER_BUILDER_NAME)" \
				--build-arg FOLDERS_TO_REMOVE="spec node_modules" \
				--build-arg BUNDLE_WITHOUT=$(BUNDLE_WITHOUT) \
				--build-arg EXECJS_RUNTIME=Disabled \
				--build-arg RAILS_ENV=production \
				--build-arg NODE_ENV=production \
				--build-arg APP_ROOT="$(APP_ROOT)" \
				--build-arg APP_VERSION="$(NAME),$(GIT_BRANCH),$(GIT_COMMIT)" \
				-t $(NAME):$(BUILD_TAG) \
				--rm -f ./dockerfiles/release_image .

base: ; $(info ======== build $(NAME) runtime image:)
	@$(BUILD_BASE_IMAGE)

builder: cpssh; $(info ======== build $(NAME) compile image:)
	@$(BUILD_BUILDER_IMAGE)

cpssh:
	@mkdir -p ssh
	@cp -R ~/.ssh/id_rsa* ssh/

clean: ; $(info ======== clean docker images: $(CLEAN_IMAGES))
	@$(CLEAN_DOCKER_IMAGES)
	@rm -rf ssh
```

## 总结

当通过多段镜像实现部分流程的显式缓存，避免大量重复网络请求，从而实现镜像打包加速。最终镜像仅包含程序文件和运行时文件，大大降低镜像的体积。

缓存镜像需要定期更新，或者依赖发生变化时清除旧的缓存镜像重新打包。

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
