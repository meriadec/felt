# The README screenshot (assets/screenshot.png): callouts with stairs and a straight
# pointer on the fixture page. The screen is big enough for the page at 1:1 with
# the panels clear of it. Regenerate: zig build shot -Dscript=readme, then copy
# test-out/shots/readme.frame.png to assets/screenshot.png.
size 1400 1100
ui tool callout
ui pointer-style straight
ui pointer-style stairs
drag 415 400 160 310
type Left target
key enter
drag 1000 430 1300 340
type Right
key enter
key 5
drag 535 610 460 460
type Above
key enter
drag 805 595 865 775
type Below
key enter
key 4
drag 1142 655 1075 625
type Short
key enter
drag 1093 722 1075 715
type Near
key enter
ui pointer-style
key 1
drag 325 625 160 565
type Straight
key enter
key ctrl+z ctrl+y
ui pointer-style stairs
