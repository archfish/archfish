---
layout:       post
title:        Ruby on Rails容器化实践（二）
subtitle:     基于Alpine的最小Docker镜像打包脚本
date:         2018-08-20 22:45:51 +0800
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

镜像的大小对容器运行资源占用并没有什么太大影响，多层次的镜像结构使得相同layout在每台docker主机上都是唯一一份，即Docker Images共享相同layout。选择[alpine][1]只是因为它易于使用且相关软件包都比较新。本文使用三个Dockerfile来分别处理Rails打包的三个阶段。

# 运行时镜像

即把Rails编译完成后的文件拷贝到该镜像上应当可以正常运行，无依赖问题。这里首先将Alpine构建为满足运行条件的镜像，然后将运行状态的Rails所依赖的包进行整理。

```shell
# ps -ef | grep puma

501 57757   868   0  4:41下午 ttys000    0:06.76 puma 3.11.0 (tcp://0.0.0.0:3000) [reocar_store]
501 60614 57757   0 10:16下午 ttys000    0:00.46 puma: cluster worker 0: 57757 [reocar_store]

# lsof -p 60614 | grep .so | grep -v ruby
ruby    30119 rails  mem       REG              252,0    27000   45613481 /lib/x86_64-linux-gnu/libnss_dns-2.23.so
ruby    30119 rails  mem       REG              252,0    89696   45613586 /lib/x86_64-linux-gnu/libgcc_s.so.1
```

将库文件放到[alpine包查询][2]里查出相应软件包，这样我们的运行时镜像就可以用下面的脚本进行打包了：

```Dockerfile
# dockerfiles/base_image

ARG FROM_IMAGE=ruby:2.3-alpine

FROM $FROM_IMAGE
LABEL maintainer=$MAINTAINER

ENV GEM_HOME /usr/local/bundle
ENV BUNDLE_PATH="$GEM_HOME" \
	BUNDLE_SILENCE_ROOT_WARNING=1 \
	BUNDLE_APP_CONFIG="$GEM_HOME"
ENV PATH $GEM_HOME/bin:$BUNDLE_PATH/gems/bin:$PATH

RUN echo 'gem: --no-document' >> /usr/local/etc/gemrc \
    && gem source --remove https://rubygems.org/ --add https://mirrors.tuna.tsinghua.edu.cn/rubygems/ \
    && gem install rubygems-update \
    && update_rubygems \
    && gem update --system \
    && rm -rf /root/.gem/specs/* \
    && rm -rf $GEM_HOME/doc/* \
    && rm -rf $GEM_HOME/cache/* \
    && mv /etc/apk/repositories /etc/apk/repositories-bak \
    && { \
        echo 'https://mirrors.aliyun.com/alpine/v3.7/main'; \
        echo 'https://mirrors.aliyun.com/alpine/v3.7/community'; \
        echo '@edge https://mirrors.aliyun.com/alpine/edge/main'; \
        echo '@testing https://mirrors.aliyun.com/alpine/edge/testing'; \
        echo '@community https://mirrors.aliyun.com/alpine/edge/community'; \
    } >> /etc/apk/repositories \
    && apk add --update --no-cache \
        libgcc libstdc++ freetds libsasl libldap libpq musl \
        file tzdata imagemagick nodejs ghostscript-fonts busybox-suid \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

CMD [ "irb" ]
```

因为我们有新旧系统共同使用，所以安装了mssql server的相关驱动。

# 编译时包

```Dockerfile
# dockerfiles/builder_image

ARG FROM_IMAGE

FROM $FROM_IMAGE

ARG APP_ROOT
ARG BUNDLE_WITHOUT

ENV RAILS_ENV=production
ENV BUNDLE_WITHOUT ${BUNDLE_WITHOUT}

RUN apk add --update --no-cache \
        openssh-client build-base git \
        freetds-dev postgresql-dev \
        postgis@testing libressl2.7-libcrypto@edge json-c@edge

ADD ssh /root/.ssh

RUN chmod 700 /root/.ssh \
    && chmod 600 /root/.ssh/id_rsa* \
    && ssh-keyscan my.git.server.com > ~/.ssh/known_hosts

WORKDIR ${APP_ROOT}

ADD Gemfile* ./

RUN bundle config --global frozen 1 \
    && bundle install -j4 --retry 3 \
    && find /usr/local/bundle/gems/ -name wkhtmltopdf_darwin* -delete \
    && find /usr/local/bundle/gems/ -name wkhtmltopdf_linux_x86 -delete \
    && rm -rf Gemfile*

CMD [ "irb" ]
```

这里将开发组件全部安装好，并配置好ssh用于拉取项目源码。同时缓存Gemfile内使用的包，这样每次可以省下不少时间。

# 发行包

```Dockerfile
# dockerfiles/release

ARG BUILDER_IMAGE
ARG RUNTIME_IMAGE

FROM $BUILDER_IMAGE as Builder

ARG FOLDERS_TO_REMOVE
ARG BUNDLE_WITHOUT
ARG RAILS_ENV
ARG NODE_ENV
ARG APP_ROOT

ENV BUNDLE_WITHOUT ${BUNDLE_WITHOUT}
ENV RAILS_ENV ${RAILS_ENV}
ENV NODE_ENV ${NODE_ENV}
ENV SECRET_KEY_BASE=foo

WORKDIR ${APP_ROOT}

COPY ./ ./

RUN mkdir -p ~/.ssh \
    && chmod 700 ~/.ssh \
    && cp ssh/* ~/.ssh/ \
    && chmod 600 ~/.ssh/id_rsa* \
    && ssh-keyscan my.git.server.com > ~/.ssh/known_hosts

RUN mkdir -p tmp/pids tmp/sockets \
    && bundle config --global frozen 1 \
    && bundle install -j4 --retry 3 \
    && bundle exec rake assets:clean[0] \
    && bundle exec rake assets:precompile \
    && bundle exec rake tmp:clear \
    && bundle exec rake log:clear \
    && rm -rf /usr/local/bundle/cache/*.gem \
    && find /usr/local/bundle/gems/ -name "*.c" -delete \
    && find /usr/local/bundle/gems/ -name "*.o" -delete \
    && rm -rf $FOLDERS_TO_REMOVE

FROM $RUNTIME_IMAGE

ARG EXECJS_RUNTIME
ARG APP_ROOT
ARG RAILS_ENV
ARG APP_VERSION

RUN addgroup -g 1001 -S rails \
    && adduser -u 1001 -S rails -G rails

USER rails

COPY --from=Builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=Builder --chown=rails:rails ${APP_ROOT} ${APP_ROOT}

ENV RAILS_ENV=${RAILS_ENV} \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true \
    EXECJS_RUNTIME=$EXECJS_RUNTIME \
    APP_VERSION=$APP_VERSION \
    SECRET_KEY_BASE=7dea1************************************************8257dfe7fc

WORKDIR ${APP_ROOT}

EXPOSE 3000

ENTRYPOINT ["/bin/sh", "./entrypoint.sh"]
CMD [ "server" ]
```

这里有两个部分，第一部分负责使用「编译时包」对源码进行编译，编译完成后将多余文件清理干净，第二部分直接将bundler的安装目录和项目编译后的文件拷贝到「运行时镜像」，并设置相关环境变量即可。

# Makefile

每次靠人力去维护这些脚本，并组合使用非常麻烦，需要写一大堆的使用文档才能让后来的人去使用。这里我们引入[Makefile][3]来帮我组织这些命令和脚本。这个脚本应当达到以下目的

- 镜像打包以后不再携带git相关信息，所以需要获取当前的版本，版本由`项目名+分支名+当前提交号组成`，这样方便查看当前代码是否正确
- 各阶段生成镜像名应当在编译时统一指定，这样可以使用已经生成的镜像进行操作，可以节省一大堆时间
- 指定项目运行目录，将目录从dockerfile中解放出来，便于维护
- 各种环境变量也应当由Makefile进行控制，可以灵活修改
- 最终生成的镜像tag应当能定制，方便与CI/CD工具整合

```Makefile
NAME				= $(shell basename -s . `git rev-parse --show-toplevel`)
GIT_COMMIT			= $(shell git rev-parse --short HEAD)
GIT_BRANCH			= $(shell git rev-parse --abbrev-ref HEAD)
DOCKER_BASE_NAME	= reocar-ruby-2.3:alpine3.7
DOCKER_BUILDER_NAME	= reocar-ruby-2.3:builder
APP_ROOT			= /opt/$(NAME)
CLEAN_IMAGES		:=
BUILD_TAG			:= $(tag)
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
				--build-arg FOLDERS_TO_REMOVE="spec node_modules app/assets vendor/assets lib/assets" \
				--build-arg BUNDLE_WITHOUT=$(BUNDLE_WITHOUT) \
				--build-arg EXECJS_RUNTIME=Disabled \
				--build-arg RAILS_ENV=production \
				--build-arg NODE_ENV=production \
				--build-arg APP_ROOT="$(APP_ROOT)" \
				--build-arg APP_VERSION="$(NAME),$(GIT_BRANCH),$(GIT_COMMIT)" \
				-t $(NAME):$(BUILD_TAG) \
				--rm -f ./dockerfiles/release .

base: ; $(info ======== build $(NAME) runtime image:)
	@$(BUILD_BASE_IMAGE)

builder: cpssh; $(info ======== build $(NAME) compile image:)
	@$(BUILD_BUILDER_IMAGE)

cpssh:
	@cp -R ~/.ssh ssh

clean: ; $(info ======== clean docker images: $(CLEAN_IMAGES))
	@$(CLEAN_DOCKER_IMAGES)
	@rm -rf ssh

```

使用方法：在项目根目录敲下`make`即可，如果需要清理缓存镜像，使用`make clean`

注意！！

请不要执行 `/bin/sh Makefile` 命令，这样既不是Makefile的正确用法，也无法预测会发生什么事情。[从前有个人执行了这个命令，然后他再也没出现过了- -\|\|][4]

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
[1]: https://alpinelinux.org/ "alpine"
[2]: https://pkgs.alpinelinux.org/contents "alpine contents search"
[3]: http://www.ruanyifeng.com/blog/2015/02/make.html "Make 命令教程"
[4]: https://github.com/fagongzi/gateway/issues/93 "什么鬼，运行了根目录下的Makefile，自动删除了我好多文件夹，包括了根目录的文件"
