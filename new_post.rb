#!/usr/bin/env ruby

unless ARGV[0]
  puts 'Usage: ./new_post.rb "the post title"'
  exit(-1)
end

title = ARGV.join ' '
date_prefix = Time.now.strftime("%Y-%m-%d")
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
catalog:      true
multilingual: true
tags:
  - tag1
  - tag2
---

#{Time.now.strftime '%Y-%m-%d'} - Guangzhou
HEAD

File.open(post, 'w') { |f| f << header }
