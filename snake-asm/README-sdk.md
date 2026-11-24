# Schnecke (Snake) for PC/GEOS 1.x

Arrow keys or W/A/S/D: the first press starts the run, further presses steer.
P: pause / resume. R or Space: restart. The snake grows by one segment per
red target and gets faster every 4 points (down to 3 ticks per step). Walls
and the snake's own body end the game. Score = snake length - 3.

The best score is kept in `STATE\SCHNECKE.SCO` (4 bytes: S,K,best,0; falls back to the top directory if STATE is not reachable),
written when a game ends, on restart and when the application closes. The file
calls use the same register sequences as an owned native game on GeoWorks 1.28.

Set `DEBUG_KEYS` to 1 in snake.nasm to show the last key as three numbers
(CL, CH, DL) in the header.

Build from the SDK root (needs the icon support patch):

    perl sdk.pl build --project examples/snake-asm

Game logic was checked in a CPU emulator with stubbed kernel calls; the real
kernel behaviour was tested by hand on one GeoWorks 1.28 installation.
