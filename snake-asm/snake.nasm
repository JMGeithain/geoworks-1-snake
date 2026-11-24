; SPDX-License-Identifier: MIT
; Snake for the Ensemble 1.2 profile of the PC/GEOS 1.x community SDK.
; Arrow keys or W A S D: the first press starts the run, further presses steer.
; P pauses/resumes, R / Space restart.  The snake grows by one segment per
; target, speeds up with the score and keeps its best score in a file.
;
; The board size follows the window size (re-checked on every expose; a
; changed size restarts the game).
;
; UNVERIFIED ASSUMPTIONS (not covered by the SDK's ABI inventory):
;  * Best-score file: the register sequences (kernel entry 76 with AX=0, then
;    FileOpen AL=C0 / FileCreate AH=1 AL=C1 / FileRead / FileWrite / FileClose)
;    are copied from an owned native game that does the same on 1.28.
;  * Arrow keys: CL = 0x90..0x93 (VC_UP, VC_DOWN, VC_RIGHT, VC_LEFT) as in GEOS 2.x.
;  * ObjMessage with DI = 0x4000 (MF_FORCE_QUEUE) to the own process handle queues
;    the tick; if it is delivered synchronously the game falls back to turn-based.
;  * MSG_META_KBD_CHAR (123): CL = character, DL = CharFlags, bit 7 = release.
;  * The code resource is writable and stays resident, so game state lives in
;    CS-relative variables below.
;  * Drawing outside an expose handler through GrCreateState(window handle)
;    is accepted by the kernel (the window handle is saved from MSG_META_EXPOSED).
%include "ensemble12.inc"
%define PROCESS_CLASS 0x40
%define GWMIN 8                 ; board size limits in cells
%define GWMAX 200
%define GHMIN 6
%define GHMAX 150
%define CELLBIG 20              ; cell size on large windows (small: 10)
%define BIGW 1400                ; window width/height from which cells are big
%define BIGH 700
%define OX 10                   ; board left
%define OB 10                   ; bottom margin (OY is a variable: header height)
%define MAXLEN 250
%define TICKS 6                 ; TimerSleep ticks between steps at the start
%define TICKMIN 3               ; fastest pace; one tick less every 4 points
%define MSG_TICK 0x0b00         ; private self-posted message
%define DEBUG_KEYS 0            ; 1 = show last key CL CH DL in the header

G1_METHOD 0x0a01, app_open
G1_METHOD 0x0a03, app_close
G1_METHOD 0x0004, meta_attach
G1_METHOD 0x0057, view_closed
G1_METHOD 0x0049, view_exposed
G1_METHOD 0x007b, kbd_char       ; MSG_META_KBD_CHAR = 123
G1_METHOD MSG_TICK, tick

app_open:
 push es
 pop ds
 mov di,PROCESS_CLASS
 KCALL 489                       ; ObjCallSuperNoLock
 retf
app_close:
 call flush_best
 mov byte [cs:running],0
 xor cx,cx
 retf
meta_attach:
 mov di,PROCESS_CLASS
 KCALL 489
 retf
view_closed:
 mov byte [cs:running],0
 inc word [cs:gen]
 mov word [cs:win],0             ; window is gone: stop drawing into it
 mov di,PROCESS_CLASS
 KCALL 489
 retf

view_exposed:
 mov [cs:win],cx                 ; CX = exposed window handle
 mov di,cx
 KCALL 211                       ; GrCreateState
 KCALL 440                       ; GrGetWinBounds -> AX,BX,CX,DX
 sub cx,ax
 inc cx
 mov [cs:winw],cx                ; window width
 sub dx,bx
 inc dx
 mov [cs:winh],dx                ; window height
 call fit_grid                   ; adapt board to the window
 KCALL 446                       ; GrBeginUpdate
 call draw_all
 KCALL 447                       ; GrEndUpdate
 KCALL 212                       ; GrDestroyState
 retf

kbd_char:
 mov [cs:lastcl],cl
 mov [cs:lastch],ch
 mov [cs:lastdl],dl
 test dl,0x81                    ; CharFlags: bit 7 state key, bit 0 key release
 jnz .ignore                     ; (release used to toggle pause a second time)
 mov al,cl
 cmp al,0x90
 jb .letters
 cmp al,0x93
 ja .letters
 sub al,0x90                     ; VC_UP, VC_DOWN, VC_RIGHT, VC_LEFT
 xor bh,bh
 mov bl,al
 mov bl,[cs:dirmap+bx]
 jmp .got
.letters:
 or al,0x20                      ; lower-case
 cmp al,'r'
 je .restart
 cmp al,' '
 je .restart
 cmp al,'p'
 je .pause
 mov bl,0
 cmp al,'w'
 je .got
 mov bl,1
 cmp al,'d'
 je .got
 mov bl,2
 cmp al,'s'
 je .got
 mov bl,3
 cmp al,'a'
 jne .ignore
.got:
 cmp byte [cs:dead],0
 jne .ignore
 cmp byte [cs:paused],0
 jne .ignore                     ; paused: only P resumes
 cmp byte [cs:inited],0
 jne .ready
 call reset_game
.ready:
 mov al,[cs:movdir]              ; direction of the last executed step
 add al,2
 and al,3
 cmp al,bl
 je .ignore                      ; no 180-degree turns
 mov [cs:dir],bl
 cmp byte [cs:loopbad],0
 jne .manual
 cmp byte [cs:running],0
 jne .ignore                     ; already running: only steer
 mov byte [cs:running],1         ; first nudge starts the run
 inc word [cs:gen]
 call post_tick
 jmp .ignore
.manual:                         ; fallback: one step per key press
 call step
 call redraw_now
 jmp .ignore
.pause:
 test dl,2                       ; ignore auto-repeat of the P key
 jnz .ignore
 cmp byte [cs:dead],0
 jne .ignore
 cmp byte [cs:loopbad],0
 jne .ignore
 cmp byte [cs:paused],0
 jne .resume
 cmp byte [cs:running],0
 je .ignore                      ; nothing to pause
 mov byte [cs:paused],1
 mov byte [cs:running],0
 inc word [cs:gen]               ; drops the queued tick
 call redraw_now
 jmp .ignore
.resume:
 mov byte [cs:paused],0
 mov byte [cs:running],1
 inc word [cs:gen]
 call post_tick
 call redraw_now
 jmp .ignore
.restart:
 call reset_game
 call redraw_now
.ignore:
%if DEBUG_KEYS
 call redraw_now
%endif
 retf

; Self-posted game tick: one step, redraw, sleep, queue the next tick.
; CX = generation; stale ticks (restart, new run, closed window) are dropped.
tick:
 cmp cx,[cs:gen]
 jne .out
 cmp byte [cs:running],0
 je .out
 cmp byte [cs:depth],0
 jne .nested                     ; delivered synchronously: not queued
 inc byte [cs:depth]
 call step
 cmp byte [cs:dead],0
 jne .full
 cmp byte [cs:ate],0
 jne .full
 call redraw_inc
 jmp .next
.full:
 call redraw_now
 cmp byte [cs:dead],0
 jne .done
.next:
 mov al,[cs:delay]
 xor ah,ah
 KCALL 184                       ; TimerSleep
 call post_tick
.done:
 dec byte [cs:depth]
.out:
 retf
.nested:
 mov byte [cs:running],0         ; queueing does not work here:
 mov byte [cs:loopbad],1         ; fall back to one step per key press
 retf

post_tick:
 KCALL 149                       ; GeodeGetProcessHandle -> BX
 mov cx,[cs:gen]
 mov ax,MSG_TICK
 xor si,si
 xor dx,dx
 xor bp,bp
 mov di,0x4000                   ; MF_FORCE_QUEUE
 KCALL 169                       ; ObjMessage
 ret

; ---------------------------------------------------------------- game logic
reset_game:
 call flush_best                 ; keep an unsaved best score
 cmp byte [cs:hsloaded],0
 jne .loaded
 mov byte [cs:hsloaded],1
 call load_best
.loaded:
 mov byte [cs:inited],1
 mov byte [cs:dead],0
 mov byte [cs:running],0
 mov byte [cs:paused],0
 mov byte [cs:delay],TICKS
 mov byte [cs:movdir],1
 mov byte [cs:erase],0
 mov byte [cs:ate],0
 inc word [cs:gen]               ; drops any queued tick
 mov byte [cs:dir],1             ; 0 up, 1 right, 2 down, 3 left
 mov byte [cs:tail],0
 mov byte [cs:head],2
 mov byte [cs:len],3
 mov ah,[cs:gh]
 shr ah,1
 mov [cs:ys],ah                  ; snake starts in the middle row
 mov [cs:ys+1],ah
 mov [cs:ys+2],ah
 mov al,[cs:gw]
 shr al,1
 dec al
 mov [cs:xs],al
 inc al
 mov [cs:xs+1],al
 inc al
 mov [cs:xs+2],al
 call place_food
 ret

; Compute the board size from the window size; restart if it changed.
fit_grid:
 mov al,[cs:gw]
 mov ah,[cs:gh]
 push ax
 call set_grid
 pop ax
 cmp byte [cs:inited],0
 je .done                        ; first run: draw_all starts the game
 cmp al,[cs:gw]
 jne .reset
 cmp ah,[cs:gh]
 je .done
.reset:
 call reset_game
.done:
 ret

set_grid:
 mov word [cs:gpx],2              ; small: cell 10, glyph pixel 2, header 26
 mov word [cs:gpx6],12
 mov word [cs:gpx7],14
 mov word [cs:hx2],100
 mov word [cs:hx3],250
 mov word [cs:oy],26
 mov word [cs:hy],5
 mov byte [cs:cell],10
 cmp word [cs:winw],BIGW
 jb .small
 cmp word [cs:winh],BIGH
 jb .small
 mov word [cs:gpx],4              ; big: cell 20, glyph pixel 4, header 46
 mov word [cs:gpx6],24
 mov word [cs:gpx7],28
 mov word [cs:hx2],200
 mov word [cs:hx3],500
 mov word [cs:oy],46
 mov word [cs:hy],8
 mov byte [cs:cell],CELLBIG
.small:
 mov ax,[cs:winw]
 sub ax,2*OX
 jnc .w1
 xor ax,ax
.w1:
 cmp ax,2000
 jbe .w2
 mov ax,2000
.w2:
 mov bl,[cs:cell]
 div bl
 cmp al,GWMAX
 jbe .w3
 mov al,GWMAX
.w3:
 cmp al,GWMIN
 jae .w4
 mov al,GWMIN
.w4:
 mov [cs:gw],al
 mov cl,[cs:cell]
 mul cl
 mov [cs:boardw],ax
 mov ax,[cs:winh]
 sub ax,[cs:oy]
 sub ax,OB
 jnc .h1
 xor ax,ax
.h1:
 cmp ax,1500
 jbe .h2
 mov ax,1500
.h2:
 mov bl,[cs:cell]
 div bl
 cmp al,GHMAX
 jbe .h3
 mov al,GHMAX
.h3:
 cmp al,GHMIN
 jae .h4
 mov al,GHMIN
.h4:
 mov [cs:gh],al
 mov cl,[cs:cell]
 mul cl
 mov [cs:boardh],ax
 ret

rand:                            ; AX = next 16-bit pseudo-random value
 mov ax,[cs:seed]
 mov dx,25173
 mul dx
 add ax,13849
 mov [cs:seed],ax
 ret

place_food:
.try:
 call rand
 mov al,ah
 xor ah,ah
 mov bl,[cs:gw]
 div bl                          ; AH = remainder
 mov [cs:fx],ah
 call rand
 mov al,ah
 xor ah,ah
 mov bl,[cs:gh]
 div bl
 mov [cs:fy],ah
 mov al,[cs:fx]
 mov ah,[cs:fy]
 call on_snake
 jc .try
 ret

; in: AL=x AH=y   out: CF=1 if the cell is part of the snake
on_snake:
 mov dl,[cs:tail]
 mov cl,[cs:len]
.loop:
 xor bh,bh
 mov bl,dl
 cmp al,[cs:xs+bx]
 jne .next
 cmp ah,[cs:ys+bx]
 je .hit
.next:
 inc dl
 dec cl
 jnz .loop
 clc
 ret
.hit:
 stc
 ret

push_head:                       ; in: AL=x AH=y
 inc byte [cs:head]
 mov bl,[cs:head]
 xor bh,bh
 mov [cs:xs+bx],al
 mov [cs:ys+bx],ah
 ret

step:
 mov al,[cs:dir]
 mov [cs:movdir],al
 mov byte [cs:erase],0
 mov byte [cs:ate],0
 xor bh,bh
 mov bl,[cs:head]
 mov al,[cs:xs+bx]
 mov ah,[cs:ys+bx]
 mov cl,[cs:dir]
 cmp cl,0
 jne .nu
 dec ah
 jmp .chk
.nu:
 cmp cl,1
 jne .nr
 inc al
 jmp .chk
.nr:
 cmp cl,2
 jne .nd
 inc ah
 jmp .chk
.nd:
 dec al
.chk:
 cmp al,[cs:gw]                 ; unsigned: -1 wraps to 255
 jae .die
 cmp ah,[cs:gh]
 jae .die
 cmp al,[cs:fx]
 jne .noeat
 cmp ah,[cs:fy]
 jne .noeat
 call on_snake                   ; eating: tail stays, so full body blocks
 jc .die
 call push_head
 mov byte [cs:ate],1
 inc byte [cs:len]
 call update_best
 call speed_up
 cmp byte [cs:len],MAXLEN
 jae .die                        ; board limit reached: game over
 call place_food
 ret
.noeat:
 mov bl,[cs:tail]                ; remember the cell to erase
 xor bh,bh
 mov cl,[cs:xs+bx]
 mov [cs:ex],cl
 mov cl,[cs:ys+bx]
 mov [cs:ey],cl
 mov byte [cs:erase],1
 inc byte [cs:tail]              ; tail moves away first
 dec byte [cs:len]
 call on_snake
 jc .die
 call push_head
 inc byte [cs:len]
 ret
.die:
 mov byte [cs:dead],1
 mov byte [cs:running],0
 call flush_best
 ret

update_best:                     ; live best score = max(best, length-3)
 mov al,[cs:len]
 sub al,3
 cmp al,[cs:best]
 jbe .no
 mov [cs:best],al
 mov byte [cs:bestdirty],1
.no:
 ret

speed_up:                        ; delay = max(TICKMIN, TICKS - score/4)
 mov al,[cs:len]
 sub al,3
 mov cl,2
 shr al,cl
 mov ah,TICKS
 sub ah,al
 jb .min
 cmp ah,TICKMIN
 jae .set
.min:
 mov ah,TICKMIN
.set:
 mov [cs:delay],ah
 ret

flush_best:
 cmp byte [cs:bestdirty],0
 je .no
 mov byte [cs:bestdirty],0
 call save_best
.no:
 ret

; Go to the top directory (entry 76, AX=0 as in an owned game), then try its
; STATE subdirectory with FileSetCurrentPath (entry 51, BX=0 = relative to the
; current directory - assumption). If that fails the file stays in the top directory.
goto_state:
 mov ax,0
 KCALL 76
 mov bx,0
 mov dx,statedir
 KCALL 51
 ret

; Best-score file: 'S','K',best,0.  Register values as used by an owned
; native game on GeoWorks 1.28 (kernel entry 76 with AX=0 precedes the open).
load_best:
 push ds
 push cs
 pop ds
 mov word [hsbuf],0
 mov word [hsbuf+2],0
 call goto_state
 mov al,0xc0
 mov dx,hsname
 KCALL 52                        ; FileOpen
 jc .out
 push ax
 mov bx,ax
 mov al,0
 mov cx,4
 mov dx,hsbuf
 KCALL 58                        ; FileRead
 pop bx
 mov ax,0
 KCALL 54                        ; FileClose
 cmp byte [hsbuf],'S'
 jne .out
 cmp byte [hsbuf+1],'K'
 jne .out
 mov al,[hsbuf+2]
 mov [best],al
.out:
 pop ds
 ret

save_best:
 push ds
 push cs
 pop ds
 call goto_state
 mov byte [hsbuf],'S'
 mov byte [hsbuf+1],'K'
 mov al,[best]
 mov [hsbuf+2],al
 mov byte [hsbuf+3],0
 mov ah,1
 mov al,0xc1
 mov cx,0
 mov dx,hsname
 KCALL 53                        ; FileCreate
 jc .out
 push ax
 mov bx,ax
 mov cx,4
 mov ax,0
 mov dx,hsbuf
 KCALL 59                        ; FileWrite
 pop bx
 mov ax,0
 KCALL 54                        ; FileClose
.out:
 pop ds
 ret

; ------------------------------------------------------------------ drawing
redraw_now:
 mov di,[cs:win]
 test di,di
 jz .none
 KCALL 211                       ; GrCreateState on the saved window
 call draw_all
 KCALL 212
.none:
 ret

; Incremental redraw after a normal step: erase tail, recolour old head, draw head.
redraw_inc:
 mov di,[cs:win]
 test di,di
 jz .none
 KCALL 211
 cmp byte [cs:erase],0
 je .noerase
 xor ax,ax
 KCALL 355
 mov al,[cs:ex]
 mov ah,[cs:ey]
 call fillcell
.noerase:
 mov ax,10
 KCALL 355
 mov bl,[cs:head]
 dec bl
 xor bh,bh
 mov al,[cs:xs+bx]
 mov ah,[cs:ys+bx]
 call fillcell
 mov ax,14
 KCALL 355
 xor bh,bh
 mov bl,[cs:head]
 mov al,[cs:xs+bx]
 mov ah,[cs:ys+bx]
 call fillcell
 KCALL 212
.none:
 ret

; AL = value -> three digit glyph indices at [CS:SI]
dec3:
 xor ah,ah
 mov bl,100
 div bl
 mov [cs:si],al
 mov al,ah
 xor ah,ah
 mov bl,10
 div bl
 mov [cs:si+1],al
 mov [cs:si+2],ah
 ret

; in: AL=gx AH=gy, DI=GState, area colour already set
fillcell:
 mov bl,ah
 mov cl,[cs:cell]
 mul cl                          ; AX = gx*CELL
 add ax,OX+1
 push ax
 mov al,bl
 mul cl                          ; AX = gy*CELL
 add ax,[cs:oy]
 inc ax
 mov bx,ax
 mov dx,ax
 mov al,[cs:cell]
 xor ah,ah
 sub ax,2
 add dx,ax
 mov cx,ax
 pop ax
 add cx,ax
 KCALL 336                       ; GrFillRect
 ret

draw_all:
 cmp byte [cs:inited],0
 jne .ok
 call reset_game
.ok:
 xor ax,ax                       ; black background
 KCALL 355
 xor ax,ax
 xor bx,bx
 mov cx,[cs:winw]
 mov dx,[cs:winh]
 KCALL 336
 mov ax,8                        ; grey frame
 KCALL 355
 mov ax,OX-2
 mov bx,[cs:oy]
 sub bx,2
 mov cx,[cs:boardw]
 add cx,OX+1
 mov dx,[cs:boardh]
 add dx,[cs:oy]
 inc dx
 KCALL 336
 xor ax,ax                       ; black board
 KCALL 355
 mov ax,OX
 mov bx,[cs:oy]
 mov cx,[cs:boardw]
 add cx,OX-1
 mov dx,[cs:boardh]
 add dx,[cs:oy]
 dec dx
 KCALL 336
 mov ax,12                       ; food
 KCALL 355
 mov al,[cs:fx]
 mov ah,[cs:fy]
 call fillcell
 mov ax,10                       ; body
 KCALL 355
 mov al,[cs:tail]
 mov [cs:iter],al
 mov al,[cs:len]
 mov [cs:cnt],al
.body:
 xor bh,bh
 mov bl,[cs:iter]
 mov al,[cs:xs+bx]
 mov ah,[cs:ys+bx]
 call fillcell
 inc byte [cs:iter]
 dec byte [cs:cnt]
 jnz .body
 mov ax,14                       ; head (yellow, red when dead)
 cmp byte [cs:dead],0
 je .hc
 mov ax,4
.hc:
 KCALL 355
 xor bh,bh
 mov bl,[cs:head]
 mov al,[cs:xs+bx]
 mov ah,[cs:ys+bx]
 call fillcell
 ; score = len-3 as three digits
 mov al,[cs:len]
 sub al,3
 xor ah,ah
 mov bl,100
 div bl
 mov [cs:numbuf],al
 mov al,ah
 xor ah,ah
 mov bl,10
 div bl
 mov [cs:numbuf+1],al
 mov [cs:numbuf+2],ah
 mov ax,15
 KCALL 355
 push ds
 push cs
 pop ds
 mov si,numbuf
 mov bp,OX
 mov bx,[cs:hy]
 call pixel_string
 mov al,[cs:best]
 mov si,bestbuf+5
 call dec3
 mov si,bestbuf
 mov bp,[cs:hx2]
 mov bx,[cs:hy]
 call pixel_string
 cmp byte [cs:dead],0
 je .nodead
 mov si,overtxt
 mov bp,[cs:hx3]
 mov bx,[cs:hy]
 call pixel_string
.nodead:
 cmp byte [cs:paused],0
 je .nopause
 mov si,pausetxt
 mov bp,[cs:hx3]
 mov bx,[cs:hy]
 call pixel_string
.nopause:
%if DEBUG_KEYS
 mov al,[cs:lastcl]
 mov si,dbgbuf
 call dec3
 mov al,[cs:lastch]
 mov si,dbgbuf+4
 call dec3
 mov al,[cs:lastdl]
 mov si,dbgbuf+8
 call dec3
 mov si,dbgbuf
 mov bp,360
 mov bx,[cs:hy]
 call pixel_string
%endif
 pop ds
 ret

; 5x7 glyph text drawn with 2x2 rectangles (same routine as the Hello example).
; DS:SI = string of glyph indices ended by 0xff, BP = left, BX = top, DI = GState.
pixel_string:
 lodsb
 cmp al,0xff
 je .done
 push si
 xor ah,ah
 mov si,ax
 mov cl,3
 shl si,cl
 add si,glyphs
 mov dh,7
.row:
 lodsb
 mov dl,5
 push bp
.column:
 test al,0x10
 jz .skip
 push ax
 push bx
 push dx
 push si
 push bp
 mov ax,bp
 mov cx,bp
 add cx,[cs:gpx]
 dec cx
 mov dx,bx
 add dx,[cs:gpx]
 dec dx
 KCALL 336
 pop bp
 pop si
 pop dx
 pop bx
 pop ax
.skip:
 shl al,1
 add bp,[cs:gpx]
 dec dl
 jnz .column
 pop bp
 add bx,[cs:gpx]
 dec dh
 jnz .row
 sub bx,[cs:gpx7]
 add bp,[cs:gpx6]
 pop si
 jmp pixel_string
.done:
 ret

; Glyph order: 0-9, G A M E O V R, space.
glyphs:
 db 14,17,19,21,25,17,14,0
 db 4,12,4,4,4,4,14,0
 db 14,17,1,2,4,8,31,0
 db 30,1,1,14,1,1,30,0
 db 2,6,10,18,31,2,2,0
 db 31,16,30,1,1,17,14,0
 db 6,8,16,30,17,17,14,0
 db 31,1,2,4,8,8,8,0
 db 14,17,17,14,17,17,14,0
 db 14,17,17,15,1,2,12,0
 db 14,17,16,23,17,17,15,0       ; G (10)
 db 14,17,17,31,17,17,17,0       ; A (11)
 db 17,27,21,21,17,17,17,0       ; M (12)
 db 31,16,16,30,16,16,31,0       ; E (13)
 db 14,17,17,17,17,17,14,0       ; O (14)
 db 17,17,17,17,17,10,4,0        ; V (15)
 db 30,17,17,30,20,18,17,0       ; R (16)
 db 0,0,0,0,0,0,0,0              ; space (17)
 db 30,17,17,30,17,17,30,0       ; B (18)
 db 15,16,16,14,1,1,30,0         ; S (19)
 db 31,4,4,4,4,4,4,0             ; T (20)
 db 30,17,17,30,16,16,16,0       ; P (21)
 db 17,17,17,17,17,17,14,0       ; U (22)
overtxt: db 10,11,12,13,17,14,15,13,16,0xff
pausetxt: db 21,11,22,19,13,0xff
bestbuf: db 18,13,19,20,17,0,0,0,0xff
hsname: db 'SCHNECKE.SCO',0
statedir: db 'STATE',0
hsbuf:  db 0,0,0,0

; ------------------------------------------------------------ game variables
win:    dw 0
winw:   dw 320
winh:   dw 180
gw:     db 30
gh:     db 15
boardw: dw 300
cell:   db 10
oy:     dw 26
gpx:     dw 2
gpx6:    dw 12
gpx7:    dw 14
hx2:    dw 100
hx3:    dw 250
hy:     dw 5
boardh: dw 150
seed:   dw 0x1234
inited: db 0
dead:   db 0
dir:    db 1
head:   db 2
tail:   db 0
len:    db 3
fx:     db 0
fy:     db 0
iter:   db 0
cnt:    db 0
numbuf: db 0,0,0,0xff
running: db 0
paused: db 0
delay:  db TICKS
best:   db 0
bestdirty: db 0
hsloaded: db 0
loopbad: db 0
depth:  db 0
movdir: db 1
erase:  db 0
ate:    db 0
ex:     db 0
ey:     db 0
lastcl: db 0
lastch: db 0
lastdl: db 0
gen:    dw 0
dbgbuf: db 0,0,0,17,0,0,0,17,0,0,0,0xff
dirmap: db 0,2,1,3
xs:     times 256 db 0
ys:     times 256 db 0
G1_FINISH
