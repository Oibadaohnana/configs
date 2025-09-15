#!/bin/sh
while true; do
  date +'%d:%m:%Y %H:%M'
  sleep $((60 - $(date +%S)))
done