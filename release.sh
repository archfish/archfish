#!/bin/sh
set -e

dir=`pwd`

bundle exec jekyll clean

bundle exec jekyll build

cd ../archfish.github.io

git init
git remote add origin git@github.com:archfish/archfish.github.io.git
git add .
git commit -m 'update'

git push -u origin master -f

cd $dir

exit 0
