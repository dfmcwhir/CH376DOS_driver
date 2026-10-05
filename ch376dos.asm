; ===========================================================================
; CH376DOS.SYS - MS-DOS block device driver for a CH376 USB host chip on an
; 8-bit ISA card (8088 and up, DOS 2.x - 6.x, FAT12 / FAT16).
;
; BUILD   nasm -f bin ch376dos.asm -o ch376dos.sys
;
; CONFIG.SYS
;   DEVICE=C:\CH376\CH376DOS.SYS @260 #0 %2
;
;   @hhh  I/O base address in HEX (default 260).
;         base+0 = CH376 data port, base+1 = CH376 command/status port
;         (CH376 A0 pin wired to ISA A0).  Change CMD_OFS below if your card
;         maps the command port somewhere else.
;   #n    IRQ number 3..7 (decimal).  0 / omitted = no interrupt, the driver
;         polls the chip.  With an IRQ the driver sleeps (HLT) during the long
;         waits (connect / mount); it still polls the chip's INT flag, so a
;         wrongly wired IRQ costs only speed, never correctness.
;   !     debug: on a failed read/write, print a one-line report (status code,
;         byte count, LBA) with BIOS INT 10h.  Use it when tracking problems.
;   +     enable WRITES.  Without it the drive is read-only (DOS reports a
;         write-protect error), which is the safe default while testing.
;   &n    experiment: wait n BIOS ticks (55 ms each) after every sector written.
;   %n    speed modifier.  The CH376 needs a short recovery time between bus
;         accesses; the driver inserts a delay loop of 48/n iterations after
;         each write.  %0 / %1 = longest delay (use on FAST machines);
;         larger values = shorter delay (use on SLOW machines, e.g. %16 on a
;         4.77 MHz XT).  If you get random read/write errors, lower n.
;
; WHAT IT DOES
;   * One removable drive.  Only the first FAT12/FAT16 partition of an MBR
;     disk is used (or a "super-floppy" with no partition table).
;   * 512-byte sectors, up to 32-bit sector numbers (DOS 3.31+ big volumes).
;   * Hot-swap: media change is detected via the CH376 connect/disconnect
;     events, DOS then re-reads the BPB.
;   * Uses CH376 sector commands DISK_READ / DISK_WRITE (one sector per
;     command) after DISK_CONNECT + DISK_MOUNT (or DISK_INIT/READY when the
;     volume is not a file system the chip understands).
;   * Only 8086 instructions are used.
;
; NOT SUPPORTED: FAT32, exFAT, NTFS, more than one LUN, 2048/4096-byte
; sectors, DOS generic IOCTL.
; ===========================================================================

        bits 16
        cpu 8086
        org 0

CMD_OFS         equ 1                   ; command/status port = base + 1

; ---- CH376 commands ------------------------------------------------------
CMD_RESET_ALL   equ 0x05
CMD_CHECK_EXIST equ 0x06
CMD_SET_USB_MODE equ 0x15
CMD_GET_STATUS  equ 0x22
CMD_RD_USB_DATA0 equ 0x27
CMD_WR_REQ_DATA equ 0x2D                ; (file layer only - NOT used for DISK_WRITE)
CMD_WR_HOST_DATA equ 0x2C               ; data for DISK_WRITE: length byte + data
CMD_DISK_CONNECT equ 0x30
CMD_DISK_MOUNT  equ 0x31
CMD_DISK_INIT   equ 0x51
CMD_DISK_READ   equ 0x54
CMD_DISK_RD_GO  equ 0x55
CMD_DISK_WRITE  equ 0x56
CMD_DISK_WR_GO  equ 0x57
CMD_DISK_READY  equ 0x59

; ---- CH376 interrupt status codes ---------------------------------------
INT_SUCCESS     equ 0x14
INT_CONNECT     equ 0x15
INT_DISCONNECT  equ 0x16
INT_DISK_READ   equ 0x1D
INT_DISK_WRITE  equ 0x1E

; ---- jumps to far targets (8086 has only short conditional jumps) --------
%macro JNEF 1
        je %%s
        jmp %1
%%s:
%endmacro
%macro JEF 1
        jne %%s
        jmp %1
%%s:
%endmacro
%macro JCF 1
        jnc %%s
        jmp %1
%%s:
%endmacro
%macro JNCF 1
        jc %%s
        jmp %1
%%s:
%endmacro

; ===========================================================================
; Device header
; ===========================================================================
header:
        dd -1                           ; next driver
        dw 0x2800                       ; block device, non-IBM format (bit 13),
                                        ; open/close/removable support (bit 11)
        dw strategy
        dw interrupt
        db 1                            ; number of units
        db 0,0,0,0,0,0,0

; ===========================================================================
; Resident data
; ===========================================================================
req_off         dw 0                    ; request header pointer (offset, segment)
req_seg         dw 0
port            dw 0x0260
speed_dly       dw 48
timeout_ticks   dw 91                   ; ~5 seconds for any single wait
irq             db 0
hw_err          db 0
mounted         db 0
changed         db 1
have_bpb        db 0
rw_write        db 0
retry           db 0
last_stat       db 0
part_lo         dw 0                    ; partition start LBA
part_hi         dw 0
lba_lo          dw 0                    ; absolute LBA for rd/wr_sector
lba_hi          dw 0
cur_lo          dw 0                    ; current DOS sector number
cur_hi          dw 0
cnt_left        dw 0
cnt_done        dw 0
buf_off         dw 0                    ; BUILD BPB scratch buffer
buf_seg         dw 0
sv_ptr          dw 0
dbg             db 0
writes_ok       db 0                    ; set by the + option
dosver          db 0
retry_n         db 3
phase           db 0                    ; which step of a transfer we are in
hw_ph           db 0                    ; step during which BUSY timed out
prev_stat       db 0
wdelay          dw 0                    ; ticks to wait after each sector written
rm_done         db 0                    ; chip already re-initialised this request
hw_stat         db 0                    ; raw status register when BUSY timed out
hist_i          db 0
hist            times 16 db 0           ; last 16 command bytes sent to the chip
last_len        db 0                    ; last chunk length the chip announced
last_cnt        dw 0                    ; bytes moved in the failed sector
vol_id          db 'NO NAME    ',0

bpb_array       dw bpb
bpb:            dw 512                  ; bytes per sector
                db 4                    ; sectors per cluster
                dw 1                    ; reserved sectors
                db 2                    ; FATs
                dw 512                  ; root entries
                dw 0x8000               ; total sectors
                db 0xF8                 ; media descriptor
                dw 32                   ; sectors per FAT
                dw 63                   ; sectors per track
                dw 255                  ; heads
                dd 0                    ; hidden sectors
                dd 0                    ; total sectors (32 bit)

cmdtab:         dw cmd_init             ; 0  INIT
                dw cmd_media            ; 1  MEDIA CHECK
                dw cmd_bpb              ; 2  BUILD BPB
                dw cmd_unknown          ; 3  IOCTL INPUT
                dw cmd_read             ; 4  INPUT
                dw cmd_unknown          ; 5
                dw cmd_unknown          ; 6
                dw cmd_unknown          ; 7
                dw cmd_write            ; 8  OUTPUT
                dw cmd_write            ; 9  OUTPUT WITH VERIFY
                dw cmd_unknown          ; 10
                dw cmd_unknown          ; 11
                dw cmd_unknown          ; 12 IOCTL OUTPUT
                dw cmd_ok               ; 13 DEVICE OPEN
                dw cmd_ok               ; 14 DEVICE CLOSE
                dw cmd_ok               ; 15 REMOVABLE MEDIA (done = removable)

; ===========================================================================
; DOS entry points
; ===========================================================================
strategy:
        mov [cs:req_off],bx
        mov [cs:req_seg],es
        retf

interrupt:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        cld
        sti
        push cs
        pop ds
        les bx,[req_off]
        mov al,[es:bx+2]
        cmp al,15
        jbe .ok
        jmp cmd_unknown
.ok:    xor ah,ah
        shl ax,1
        mov si,ax
        jmp word [cmdtab+si]

cmd_unknown:
        mov ax,0x8103
        jmp short setstat
err_unit:
        mov ax,0x8101
        jmp short setstat
err_notready:
        mov ax,0x8102
        jmp short setstat
err_media:
        mov ax,0x8107
        jmp short setstat
err_write:
        mov ax,0x810A
        jmp short setstat
err_read:
        mov ax,0x810B
        jmp short setstat
cmd_ok:
done:
        mov ax,0x0100
setstat:
        les bx,[req_off]
        mov [es:bx+3],ax
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        retf

; ===========================================================================
; MEDIA CHECK
; ===========================================================================
cmd_media:
        cmp byte [es:bx+1],0
        JNEF err_unit
        mov byte [hw_err],0
        cmp byte [have_bpb],0
        jne .a
        jmp .changed
.a:     call ch_int_pending             ; connect/disconnect event waiting?
        jnc .noevt
        call ch_get_status
        cmp al,INT_CONNECT
        je .evt
        cmp al,INT_DISCONNECT
        jne .noevt
.evt:   mov byte [changed],1
        mov byte [mounted],0
.noevt: cmp byte [changed],0
        jne .changed
        cmp byte [mounted],0
        jne .chk
        call ch_mount                   ; lost the mount (after an error)
        jc .lost
        jmp short .same
.chk:   mov al,CMD_DISK_CONNECT
        call ch_cmd
        call ch_wait_status
        jc .lost
        cmp al,INT_SUCCESS
        jne .lost
.same:  mov al,1                        ; not changed
        jmp short .ret
.lost:  mov byte [changed],1
        mov byte [mounted],0
.changed:
        mov al,0xFF                     ; changed
.ret:   les bx,[req_off]
        mov [es:bx+14],al
        mov word [es:bx+15],vol_id
        mov [es:bx+17],cs
        jmp done

; ===========================================================================
; BUILD BPB
; ===========================================================================
cmd_bpb:
        cmp byte [es:bx+1],0
        JNEF err_unit
        mov byte [hw_err],0
        cmp byte [mounted],0
        jne .m
        call ch_mount
        JCF err_notready
.m:     les bx,[req_off]
        les di,[es:bx+14]               ; ES:DI = DOS scratch sector buffer
        mov [buf_off],di
        mov [buf_seg],es
        xor ax,ax
        mov [part_lo],ax
        mov [part_hi],ax
        mov [lba_lo],ax
        mov [lba_hi],ax
        call rd_retry
        JCF err_read
        call is_boot
        jnc .have
        call find_part
        JCF err_media
        mov ax,[part_lo]
        mov [lba_lo],ax
        mov ax,[part_hi]
        mov [lba_hi],ax
        mov di,[buf_off]
        mov es,[buf_seg]
        call rd_retry
        JCF err_read
        call is_boot
        JCF err_media
.have:  push ds                         ; copy 25-byte BPB from the boot sector
        mov ax,es
        mov si,[buf_off]
        add si,0x0B
        mov bx,ds
        mov ds,ax
        mov es,bx
        mov di,bpb
        mov cx,25
        rep movsb
        pop ds
        xor ax,ax                       ; DOS sectors are partition-relative
        mov [bpb+17],ax
        mov [bpb+19],ax
        cmp word [bpb+13],0
        jne .s1
        mov word [bpb+13],63
.s1:    cmp word [bpb+15],0
        jne .s2
        mov word [bpb+15],255
.s2:    cmp byte [dosver],7             ; DOS before 7.0: clusters <= 32 KB,
        jae .okbig                      ; volume <= 2 GB
        cmp byte [bpb+2],64
        ja .bigbad
        cmp word [bpb+8],0
        jne .okbig
        mov ax,[bpb+23]
        cmp ax,0x0040
        jb .okbig
        ja .bigbad
        cmp word [bpb+21],0
        je .okbig
.bigbad:
        mov si,msg_big
        call tty_str
        jmp err_media
.okbig: mov byte [have_bpb],1
        mov byte [changed],0
        les bx,[req_off]
        mov word [es:bx+18],bpb
        mov [es:bx+20],cs
        jmp done

; is_boot: ES:[buf_off] looks like a FAT12/16 boot sector?  CF=1 if not
is_boot:
        push ax
        push si
        mov si,[buf_off]
        cmp word [es:si+0x1FE],0xAA55
        jne .no
        cmp word [es:si+0x0B],512
        jne .no
        mov al,[es:si+0x0D]
        or al,al
        jz .no
        mov ah,al
        dec ah
        test al,ah                      ; power of two?
        jnz .no
        cmp word [es:si+0x0E],0
        je .no
        mov al,[es:si+0x10]
        cmp al,1
        jb .no
        cmp al,2
        ja .no
        cmp word [es:si+0x11],0         ; root entries (0 = FAT32)
        je .no
        cmp word [es:si+0x16],0         ; FAT size (0 = FAT32)
        je .no
        pop si
        pop ax
        clc
        ret
.no:    pop si
        pop ax
        stc
        ret

; find_part: ES:[buf_off] = MBR.  Pick first FAT12/16 partition -> part_lo/hi
find_part:
        push ax
        push cx
        push si
        mov si,[buf_off]
        cmp word [es:si+0x1FE],0xAA55
        jne .no
        add si,0x1BE
        mov cx,4
.l:     mov al,[es:si+4]
        cmp al,0x01
        je .found
        cmp al,0x04
        je .found
        cmp al,0x06
        je .found
        cmp al,0x0E
        je .found
        add si,16
        loop .l
.no:    pop si
        pop cx
        pop ax
        stc
        ret
.found: mov ax,[es:si+8]
        mov [part_lo],ax
        mov ax,[es:si+10]
        mov [part_hi],ax
        pop si
        pop cx
        pop ax
        clc
        ret

; ===========================================================================
; INPUT / OUTPUT / OUTPUT WITH VERIFY
; ===========================================================================
cmd_read:
        mov byte [rw_write],0
        jmp short do_rw
cmd_write:
        cmp byte [writes_ok],0
        jne .go
        mov ax,0x8100                   ; write-protect violation
        jmp setstat
.go:    mov byte [rw_write],1
do_rw:
        cmp byte [es:bx+1],0
        JNEF err_unit
        mov byte [hw_err],0
        mov byte [hw_ph],0
        mov byte [rm_done],0
        mov al,3
        cmp byte [rw_write],0
        je .rn
        mov al,1                        ; never retry a failed write
.rn:    mov [retry_n],al
        cmp byte [mounted],0
        jne .m
        call ch_mount
        JCF err_notready
.m:     les bx,[req_off]
        mov ax,[es:bx+20]               ; start sector (16 bit)
        xor dx,dx
        cmp ax,0xFFFF
        jne .have
        mov ax,[es:bx+26]               ; start sector (32 bit)
        mov dx,[es:bx+28]
.have:  mov [cur_lo],ax
        mov [cur_hi],dx
        mov ax,[es:bx+18]               ; sector count
        mov [cnt_left],ax
        mov word [cnt_done],0
        cmp byte [rw_write],0
        jne .setw
        les di,[es:bx+14]               ; read: ES:DI = destination
        jmp .test
.setw:  les si,[es:bx+14]               ; write: ES:SI = source
        jmp .test
.body:  mov ax,[cur_lo]                 ; LBA = DOS sector + partition start
        mov dx,[cur_hi]
        add ax,[part_lo]
        adc dx,[part_hi]
        mov [lba_lo],ax
        mov [lba_hi],dx
        mov al,[retry_n]
        mov [retry],al
.try:   cmp byte [rw_write],0
        jne .w
        call rd_sector
        jmp short .chk
.w:     call wr_sector
.chk:   jnc .ok
        cmp byte [dbg],0                ; debug: report EVERY failed attempt
        je .nr
        call dbg_report
.nr:    dec byte [retry]
        jnz .try
        cmp byte [rw_write],0           ; never re-drive a failed write
        JNEF .fail
        cmp byte [hw_err],0             ; chip wedged (BUSY stuck)?
        JEF .fail                        ; no: report the error
        cmp byte [rm_done],0
        JNEF .fail
        mov byte [rm_done],1            ; yes: reset + remount once, then retry
        call ch_mount
        JCF .fail
        mov al,[retry_n]
        mov [retry],al
        jmp .try
.ok:    cmp byte [rw_write],0
        je .nw
        mov cx,[wdelay]
        jcxz .nw
        call delay_ticks
.nw:    add word [cur_lo],1
        adc word [cur_hi],0
        dec word [cnt_left]
        inc word [cnt_done]
.test:  cmp word [cnt_left],0
        je .fin2
        jmp .body                       ; (too far for a short jump)
.fin2:  les bx,[req_off]
        mov ax,[cnt_done]
        mov [es:bx+18],ax
        jmp done
.fail:  mov byte [mounted],0
        cmp byte [rw_write],0
        je .nw2
        mov byte [changed],1            ; media state unknown after a failed write
.nw2:   cmp byte [rm_done],0            ; debug: state after a failed remount
        je .nodbg
        cmp byte [dbg],0
        je .nodbg
        call dbg_report
.nodbg: cmp byte [last_stat],INT_DISCONNECT
        jne .nd
        mov byte [changed],1
.nd:    les bx,[req_off]
        mov ax,[cnt_done]
        mov [es:bx+18],ax
        cmp byte [last_stat],INT_DISCONNECT
        JEF err_notready
        cmp byte [rw_write],0
        JNEF err_write
        jmp err_read

; ===========================================================================
; Sector transfer.  LBA in lba_lo/lba_hi.  CF=1 on error (last_stat = status)
; ===========================================================================
send_lba:
        mov al,[lba_lo]
        call ch_wr
        mov al,[lba_lo+1]
        call ch_wr
        mov al,[lba_hi]
        call ch_wr
        mov al,[lba_hi+1]
        call ch_wr
        mov al,1                        ; one sector
        call ch_wr
        ret

; rd_sector: read 512 bytes to ES:DI (DI advanced)
rd_sector:
        push bx
        push cx
        push dx
        mov [sv_ptr],di
        mov byte [phase],0x11
        mov byte [last_stat],0
        mov byte [prev_stat],0
        mov byte [last_len],0xEE
        mov al,CMD_DISK_READ
        call ch_cmd
        mov byte [phase],0x12
        call send_lba
        xor bx,bx                       ; bytes received
.loop:  mov byte [phase],0x13
        call ch_wait_status
        mov ah,[last_stat]
        mov [prev_stat],ah
        mov [last_stat],al
        jc .err
        cmp al,INT_DISK_READ
        je .data
        cmp al,INT_SUCCESS
        jne .err
        cmp bx,512
        jne .err
        clc
        jmp short .ret1
.data:  mov byte [phase],0x14
        mov al,CMD_RD_USB_DATA0
        call ch_cmd
        mov byte [phase],0x15
        call ch_rd                      ; chunk length (<= 64)
        mov [last_len],al
        xor ch,ch
        mov cl,al
        jcxz .go
        add bx,cx
        cmp bx,512
        ja .err
        mov byte [phase],0x16
.bl:    call ch_rd
        stosb
        loop .bl
.go:    mov byte [phase],0x17
        mov al,CMD_DISK_RD_GO
        call ch_cmd
        jmp .loop
.err:   mov [last_cnt],bx
        mov di,[sv_ptr]
        stc
.ret1:  pop dx
        pop cx
        pop bx
        ret

; wr_sector: write 512 bytes from ES:SI (SI advanced)
wr_sector:
        push bx
        push cx
        push dx
        mov [sv_ptr],si
        mov byte [phase],1
        mov byte [last_stat],0
        mov byte [prev_stat],0
        mov byte [last_len],0xEE
        mov al,CMD_DISK_WRITE
        call ch_cmd
        mov byte [phase],2
        call send_lba
        xor bx,bx
.loop:  mov byte [phase],3
        call ch_wait_status
        mov ah,[last_stat]
        mov [prev_stat],ah
        mov [last_stat],al
        jc .err
        cmp al,INT_DISK_WRITE
        je .req
        cmp al,INT_SUCCESS
        jne .err
        cmp bx,512
        jne .err
        clc
        jmp short .ret1
.req:   mov byte [phase],4
        mov al,CMD_WR_HOST_DATA         ; load the USB endpoint send buffer
        call ch_cmd
        mov byte [phase],5
        mov al,64
        call ch_wr                      ; chunk length
        mov byte [last_len],64
        mov cx,64
        add bx,cx
        cmp bx,512
        ja .err
        mov byte [phase],6
.bl:    mov al,[es:si]
        inc si
        call ch_wr
        loop .bl
.go:    mov byte [phase],7
        mov al,CMD_DISK_WR_GO
        call ch_cmd
        jmp .loop
.err:   mov [last_cnt],bx
        mov si,[sv_ptr]
        stc
.ret1:  pop dx
        pop cx
        pop bx
        ret

rd_retry:                               ; rd_sector, up to 3 tries
        mov byte [retry],3
.t:     call rd_sector
        jnc .ok
        dec byte [retry]
        jnz .t
        stc
        ret
.ok:    ret

; ===========================================================================
; CH376 session: reset, probe, USB host mode, connect, mount
;   CF=1 on failure
; ===========================================================================
ch_mount:
        push bx
        push cx
        call ch_hw_init
        jc .fail
        call ch_wait_status             ; wait for "device connected"
        cmp al,INT_CONNECT
        jne .fail
        mov al,CMD_DISK_CONNECT
        call ch_cmd
        call ch_wait_status
        cmp al,INT_SUCCESS
        jne .fail
        mov bx,5
.try:   mov al,CMD_DISK_MOUNT           ; some sticks need several tries
        call ch_cmd
        call ch_wait_status
        cmp al,INT_SUCCESS
        je .ok
        mov cx,2
        call delay_ticks
        dec bx
        jnz .try
        mov al,CMD_DISK_INIT            ; not a FS the chip understands:
        call ch_cmd                     ; raw initialisation is enough
        call ch_wait_status
        cmp al,INT_SUCCESS
        jne .fail
        mov bx,10
.rdy:   mov al,CMD_DISK_READY
        call ch_cmd
        call ch_wait_status
        cmp al,INT_SUCCESS
        je .ok
        mov cx,2
        call delay_ticks
        dec bx
        jnz .rdy
.fail:  mov byte [mounted],0
        pop cx
        pop bx
        stc
        ret
.ok:    mov byte [mounted],1
        pop cx
        pop bx
        clc
        ret

; ch_hw_init: reset the chip, check it exists, select USB host mode (CF=1 = fail)
ch_hw_init:
        push cx
        push dx
        mov byte [hw_err],0
        mov dx,[port]
        add dx,CMD_OFS
        mov al,CMD_RESET_ALL
        out dx,al                       ; raw write: chip is not ready yet
        mov cx,2                        ; >= 35 ms
        call delay_ticks
        mov al,CMD_CHECK_EXIST
        call ch_cmd
        mov al,0x57
        call ch_wr
        call ch_rd
        cmp al,0xA8                     ; chip answers with NOT of $57
        jne .fail
        mov al,CMD_SET_USB_MODE
        call ch_cmd
        mov al,6                        ; host mode, automatic SOF
        call ch_wr
        mov cx,200                      ; >= 20 us
.d:     loop .d
        call ch_rd
        cmp al,0x51
        jne .fail
        cmp byte [hw_err],0
        jne .fail
        pop dx
        pop cx
        clc
        ret
.fail:  pop dx
        pop cx
        stc
        ret

; ===========================================================================
; CH376 low level.  All routines preserve every register except AX where noted.
; ===========================================================================
io_delay:                               ; recovery time, scaled by %n
        push cx
        mov cx,[speed_dly]
        jcxz .z
.l:     loop .l
.z:     pop cx
        ret

ch_wait_busy:                           ; spin until BUSY (status bit 4) = 0
        cmp byte [hw_err],0
        jne .r
        push ax
        push cx
        push dx
        mov dx,[port]
        add dx,CMD_OFS
        mov cx,2000                     ; fast path: normally clear at once
.l:     in al,dx
        test al,0x10
        jz .ok
        loop .l
        call busy_slow
.ok:    pop dx
        pop cx
        pop ax
.r:     ret

busy_slow:                              ; DX = status port; allow ~1 s
        push ax
        push bx
        push es
        mov ax,0x40
        mov es,ax
        mov bx,[es:0x6C]
.s:     in al,dx
        test al,0x10
        jz .x
        mov ax,[es:0x6C]
        sub ax,bx
        cmp ax,19
        jb .s
        mov [hw_stat],al
        mov al,[phase]
        mov [hw_ph],al
        mov byte [hw_err],1             ; chip never became ready
.x:     pop es
        pop bx
        pop ax
        ret

ch_cmd:                                 ; AL = command code
        push dx
        push ax
        push bx
        mov bl,[hist_i]                 ; log it in the history ring
        xor bh,bh
        mov [hist+bx],al
        inc bl
        and bl,15
        mov [hist_i],bl
        pop bx
        call ch_wait_busy
        mov dx,[port]
        add dx,CMD_OFS
        pop ax
        out dx,al
        call io_delay
        pop dx
        ret

ch_wr:                                  ; AL = data byte
        push dx
        push ax
        call ch_wait_busy
        mov dx,[port]
        pop ax
        out dx,al
        call io_delay
        pop dx
        ret

ch_rd:                                  ; returns AL = data byte
        push dx
        call ch_wait_busy
        mov dx,[port]
        in al,dx
        pop dx
        ret

ch_int_pending:                         ; CF=1 if INT# is asserted
        push ax
        push dx
        mov dx,[port]
        add dx,CMD_OFS
        in al,dx
        test al,0x80
        pop dx
        pop ax
        jz .y
        clc
        ret
.y:     stc
        ret

ch_wait_int:                            ; wait for INT#; CF=1 on timeout
        push ax
        push bx
        push cx
        push dx
        push es
        cmp byte [hw_err],0
        jne .fail
        mov ax,0x40
        mov es,ax
        mov bx,[es:0x6C]                ; BIOS tick count (low word)
        mov dx,[port]
        add dx,CMD_OFS
        xor cx,cx
.poll:  in al,dx
        test al,0x80
        jz .ok
        mov ax,[es:0x6C]
        sub ax,bx
        cmp ax,[timeout_ticks]
        jae .fail
        cmp byte [irq],0
        je .poll
        inc cx
        cmp cx,300                      ; polled for a while: sleep until the
        jb .poll                        ; chip's IRQ (or the timer tick) wakes us
        sti
        hlt
        jmp .poll
.ok:    clc
        jmp short .x
.fail:  stc
.x:     pop es
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ch_get_status:                          ; AL = status (also releases INT#)
        mov al,CMD_GET_STATUS
        call ch_cmd
        call ch_rd
        ret

ch_wait_status:                         ; AL = status, CF=1 timeout (AL=FF)
        call ch_wait_int
        jc .to
        call ch_get_status
        clc
        ret
.to:    mov al,0xFF
        stc
        ret

delay_ticks:                            ; wait CX BIOS timer ticks (18.2 Hz)
        push ax
        push bx
        push es
        mov ax,0x40
        mov es,ax
        mov bx,[es:0x6C]
.l:     mov ax,[es:0x6C]
        sub ax,bx
        cmp ax,cx
        jb .l
        pop es
        pop bx
        pop ax
        ret

; ---- IRQ service routine: just acknowledge the 8259 --------------------
irq_isr:
        push ax
        mov al,0x20
        out 0x20,al
        pop ax
        iret

; ---- debug report via BIOS teletype (only used with the ! option) --------
dbg_report:
        push ax
        push bx
        push cx
        push si
        mov si,msg_dbg1
        call tty_str
        mov al,'R'
        cmp byte [rw_write],0
        je .r
        mov al,'W'
.r:     call tty_char
        mov si,msg_dbg2
        call tty_str
        mov al,[last_stat]
        call tty_hex_byte
        mov si,msg_dbg3
        call tty_str
        mov ax,[last_cnt]
        call tty_hex_word
        mov si,msg_dbg4
        call tty_str
        mov al,[last_len]
        call tty_hex_byte
        mov si,msg_dbg5
        call tty_str
        mov al,[hw_err]
        call tty_hex_byte
        mov si,msg_dbg7
        call tty_str
        mov al,[hw_ph]
        call tty_hex_byte
        mov si,msg_dbg8
        call tty_str
        mov al,[phase]
        call tty_hex_byte
        mov si,msg_dbg9
        call tty_str
        mov al,[prev_stat]
        call tty_hex_byte
        mov si,msg_dbg6
        call tty_str
        mov ax,[lba_hi]
        call tty_hex_word
        mov ax,[lba_lo]
        call tty_hex_word
        mov si,msg_dbgA
        call tty_str
        mov al,[hw_stat]
        call tty_hex_byte
        mov si,msg_dbgB
        call tty_str
        mov bl,[hist_i]                 ; oldest entry first
        xor bh,bh
        mov cx,16
.h:     mov al,[hist+bx]
        call tty_hex_byte
        mov al,' '
        call tty_char
        inc bl
        and bl,15
        loop .h
        mov si,msg_crlf
        call tty_str
        pop si
        pop cx
        pop bx
        pop ax
        ret

tty_char:                               ; AL
        push ax
        push bx
        mov ah,0x0E
        xor bx,bx
        int 0x10
        pop bx
        pop ax
        ret

tty_str:                                ; DS:SI -> zero terminated string
        push ax
        push si
.l:     lodsb
        or al,al
        jz .e
        call tty_char
        jmp .l
.e:     pop si
        pop ax
        ret

tty_hex_word:                           ; AX
        push ax
        mov al,ah
        call tty_hex_byte
        pop ax
tty_hex_byte:                           ; AL
        push ax
        push cx
        mov cl,4
        shr al,cl
        call tty_nib
        pop cx
        pop ax
        and al,0x0F
tty_nib:
        add al,'0'
        cmp al,'9'
        jbe .p
        add al,7
.p:     jmp tty_char

msg_dbg1        db 13,10,'CH376 error: ',0
msg_dbg2        db ' stat=',0
msg_dbg3        db ' bytes=',0
msg_dbg4        db ' req=',0
msg_dbg5        db ' hw=',0
msg_dbg6        db ' lba=',0
msg_dbg7        db ' busy@=',0
msg_dbg8        db ' phase=',0
msg_dbg9        db ' prev=',0
msg_dbgA        db ' raw=',0
msg_dbgB        db 13,10,' cmds: ',0
msg_crlf        db 13,10,0
msg_big         db 13,10,'CH376: volume has clusters >32K or is >2GB; this DOS cannot use it',13,10,0

        align 16
resident_end:

; ###########################################################################
; Everything below is discarded after INIT
; ###########################################################################
speed           dw 0
irq_tmp         dw 0
drvchar         db 'A'

msg_ok1         db 'CH376 DOS driver: I/O port $'
msg_ok2         db 'h, IRQ $'
msg_ok3         db ', speed $'
msg_ok4         db ', drive $'
crlf            db 13,10,'$'
msg_dbgon       db ' (debug on)$'
msg_ro          db ' [READ-ONLY: add + to enable writes]$'
msg_nocard      db 'CH376 DOS driver: no CH376 answered at I/O port $'
msg_badirq      db 'CH376 DOS driver: IRQ must be 3-7, running without IRQ',13,10,'$'

cmd_init:
        les bx,[req_off]
        lds si,[es:bx+18]               ; DS:SI -> text after "DEVICE="
        call parse_cmdline
        push cs
        pop ds

        mov bx,[speed]                  ; speed -> delay loop count
        or bx,bx
        jnz .sp
        inc bx
.sp:    mov ax,48
        xor dx,dx
        div bx
        mov [speed_dly],ax

        mov ax,[irq_tmp]
        or ax,ax
        jz .noirq
        cmp ax,3
        jb .badirq
        cmp ax,7
        ja .badirq
        mov [irq],al
        jmp short .noirq
.badirq:
        mov dx,msg_badirq
        call print_str
.noirq:
        call ch_hw_init                 ; reset + probe + USB host mode
        jnc .found
        mov dx,msg_nocard
        call print_str
        mov ax,[port]
        call print_hex_word
        mov dx,crlf
        call print_str
        les bx,[req_off]                ; install nothing
        mov byte [es:bx+13],0
        mov word [es:bx+14],0
        mov [es:bx+16],cs
        mov word [es:bx+18],0
        mov [es:bx+20],cs
        jmp done

.found: cmp byte [irq],0
        je .nohook
        xor ah,ah                       ; hook INT 08h+irq, unmask the IRQ
        mov al,[irq]
        add al,8
        shl ax,1
        shl ax,1
        mov di,ax
        xor ax,ax
        mov es,ax
        cli
        mov word [es:di],irq_isr
        mov [es:di+2],cs
        mov cl,[irq]
        mov ah,1
        shl ah,cl
        not ah
        in al,0x21
        and al,ah
        out 0x21,al
        sti
.nohook:
        mov dx,msg_ok1
        call print_str
        mov ax,[port]
        call print_hex_word
        mov dx,msg_ok2
        call print_str
        mov al,[irq]
        xor ah,ah
        call print_dec
        mov dx,msg_ok3
        call print_str
        mov ax,[speed]
        call print_dec
        mov ah,0x30                     ; DOS version >= 3: drive letter known
        int 0x21
        mov [dosver],al
        cmp al,3
        jb .nodrv
        les bx,[req_off]
        mov al,[es:bx+22]
        add al,'A'
        mov [drvchar],al
        mov dx,msg_ok4
        call print_str
        mov dl,[drvchar]
        mov ah,2
        int 0x21
        mov dl,':'
        mov ah,2
        int 0x21
.nodrv: cmp byte [writes_ok],0
        jne .wok
        mov dx,msg_ro
        call print_str
.wok:   cmp byte [dbg],0
        je .nd2
        mov dx,msg_dbgon
        call print_str
.nd2:   mov dx,crlf
        call print_str

        les bx,[req_off]
        mov byte [es:bx+13],1           ; one unit
        mov word [es:bx+14],resident_end
        mov [es:bx+16],cs
        mov word [es:bx+18],bpb_array
        mov [es:bx+20],cs
        jmp done

; ---- command line:  <file name> @hex #dec %dec ---------------------------
parse_cmdline:
.name:  lodsb                           ; skip our own file name
        cmp al,' '
        je .args
        cmp al,9
        je .args
        cmp al,13
        je .fin
        cmp al,10
        je .fin
        or al,al
        je .fin
        jmp .name
.args:  lodsb
        cmp al,' '
        je .args
        cmp al,9
        je .args
        cmp al,13
        je .fin
        cmp al,10
        je .fin
        or al,al
        je .fin
        cmp al,'@'
        je .p
        cmp al,'#'
        je .i
        cmp al,'%'
        je .s
        cmp al,'!'
        je .d
        cmp al,'&'
        je .w
        cmp al,'+'
        je .e
        jmp .args
.fin:   ret
.p:     call parse_hex
        mov [cs:port],ax
        jmp .args
.i:     call parse_dec
        mov [cs:irq_tmp],ax
        jmp .args
.s:     call parse_dec
        mov [cs:speed],ax
        jmp .args
.d:     mov byte [cs:dbg],1
        jmp .args
.w:     call parse_dec
        mov [cs:wdelay],ax
        jmp .args
.e:     mov byte [cs:writes_ok],1
        jmp .args

parse_hex:                              ; DS:SI -> digits, returns AX
        push cx
        push dx
        xor dx,dx
.l:     lodsb
        cmp al,'0'
        jb .e
        cmp al,'9'
        jbe .dig
        and al,0xDF
        cmp al,'A'
        jb .e
        cmp al,'F'
        ja .e
        sub al,'A'-10
        jmp short .acc
.dig:   sub al,'0'
.acc:   mov cl,4
        shl dx,cl
        xor ah,ah
        or dx,ax
        jmp .l
.e:     dec si
        mov ax,dx
        pop dx
        pop cx
        ret

parse_dec:                              ; DS:SI -> digits, returns AX
        push bx
        push dx
        xor dx,dx
.l:     lodsb
        cmp al,'0'
        jb .e
        cmp al,'9'
        ja .e
        sub al,'0'
        xor ah,ah
        mov bx,ax                       ; digit
        mov ax,dx                       ; dx*10 = (dx*4+dx)*2
        shl ax,1
        shl ax,1
        add ax,dx
        shl ax,1
        add ax,bx
        mov dx,ax
        jmp .l
.e:     dec si
        mov ax,dx
        pop dx
        pop bx
        ret

; ---- console output (DOS INT 21h, allowed during INIT) ------------------
print_str:                              ; DX -> '$' terminated string
        mov ah,9
        int 0x21
        ret

print_hex_word:                         ; AX
        push ax
        mov al,ah
        call print_hex_byte
        pop ax
print_hex_byte:                         ; AL
        push ax
        push cx
        mov cl,4
        shr al,cl
        call print_nib
        pop cx
        pop ax
        and al,0x0F
print_nib:
        add al,'0'
        cmp al,'9'
        jbe .p
        add al,7
.p:     mov dl,al
        mov ah,2
        int 0x21
        ret

print_dec:                              ; AX unsigned decimal
        xor cx,cx
        mov bx,10
.d:     xor dx,dx
        div bx
        push dx
        inc cx
        or ax,ax
        jnz .d
.p:     pop dx
        add dl,'0'
        mov ah,2
        int 0x21
        loop .p
        ret
