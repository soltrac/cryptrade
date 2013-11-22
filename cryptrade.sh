#! /bin/bash

while :
do
    node_modules/.bin/iced cryptrade.coffee "$@"
    sleep 15
done
