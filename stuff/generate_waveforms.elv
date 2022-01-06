#!/bin/elvish

var target-height = 450
var real-height = 150
var width = 1500
var color = '#9cf42f'
var gain = -4
var padding = (/ (- $target-height $real-height) 2)

use path
use str

find -L music -mindepth 2 -type d | each {|dir|
    var out = waveform/(path:base $dir).png
    if ?(test -f $out) { continue }
    echo Generating $out
    echo ffmpeg -hide_banner -i concat:(str:join '|' [$dir/*]) -filter_complex '[0:a]aformat=channel_layouts=mono,compand=gain='$gain',showwavespic=s='$width'x'$real-height':colors='$color',pad=height='$target-height':y='$padding':color=0x00000000' -loglevel quiet $out
}
