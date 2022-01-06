#!/bin/elvish

use path

var w = 150
var h = 150
var thumb-dir = thumbs
use re
find covers -name '*png' -or -name '*jpg' | each {|f|
    var out = $thumb-dir/(re:replace '_\d+\.(png|jpg)$' '' (path:base $f))'_'$w'_'$h
    if ?(test -f $out) { continue }
    echo Generating $out
    ffmpeg -i $f -vf 'scale=w='$w':h='$h -y -f rawvideo -pix_fmt bgra -c:v rawvideo -frames:v 1 -loglevel quiet $out
}
