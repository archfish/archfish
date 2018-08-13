#!/usr/bin/env ruby

DefaultDist = '../archfish.github.io/'.freeze
DefaultRepo = 'git@github.com:archfish/archfish.github.io.git'.freeze

def new_post(*args)
  title = args.join ' '
  date_prefix = Time.now.strftime('%Y-%m-%d')
  postname = title.strip.downcase.gsub(/ /, '-')
  post = "./_posts/#{date_prefix}-#{postname}.md"

  header = <<-HEAD
---
layout:       post
title:        #{title}
subtitle:     #{title}
date:         #{Time.now}
author:       Archfish
header-img:   "img/here/custom/header/image.png"
header-mask:  0.1
multilingual: false
tags:
  - tag1
  - tag2
---

- - -

欢迎跟我交流 [Archfish][0]

[0]: https://github.com/archfish/archfish "archfish blog"
  HEAD

  File.open(post, 'w') { |f| f << header }

  puts "created file #{post}"
end

def publish(*args)
  dist, repo, _ = *args
  dist ||= DefaultDist
  repo ||= DefaultRepo

  jekyll_action(dist)
  git_action(dist, repo)
end

def jekyll_action(dist)
  # !! Danger !!
  # unless dist.empty?
  #   Dir.chdir(dist) do
  #     Dir.rmdir('./*')
  #     puts "remove #{Dir.getwd}"
  #   end
  # end
  system('bundle exec jekyll build')
end

def git_action(dist, repo)
  git_cmd = ["cd #{dist}"]
  unless Dir.exist?(File.join(dist, '.git'))
    git_cmd.concat [
      'git init',
      "git remote add origin #{repo}"
    ]
  end

  git_cmd.concat [
    'git add .',
    "git commit -m 'updated at #{Time.now}'",
    'git push -u origin master' # if fail use -f
  ]
  git_cmd_str = git_cmd.join(' && ')

  puts git_cmd_str

  system(git_cmd_str)
end

def usage_info
  puts <<-USAGE
Usage:
  ./tool.rb COMMAND ARGS

  COMMAND
    new     new a blog post
    publish build blog and push to github

  EXAMPLE
    create a post name 'my_first_blog_post':

      ./tool.rb new my first blog post

    build and commit to github repo:

      ./tool.rb publish ../archfish.github.io git@github.com:archfish/archfish.github.io.git

    or post to default github repo:

      ./tool.rb publish
    USAGE

  exit(-1)
end

args0 = ARGV[0]

args = ARGV[1..-1]

case args0.to_s.downcase
when 'new'
  usage_info if (args || []).empty?

  new_post(*args)
when 'publish'
  publish(*args)
else
  usage_info
end

exit(0)
