# CH376DOS_driver
CH376DOS mass storage usb driver for DOS


DOS Driver for the CH376 chip to enable usb mass storage. Made using AI, may have bugs, may corrupt your drive, use with caution! It does work for me on an ISA card with a CH376 module on it addressed at a base address of 260h. I successfully did read and writes a 1GB thumb drive formatted as FAT in non-interrupt mode. No speed or other testing has been done

While working with AI to create this driver, the initial versions would fail to write to the drive and also led to corrupted on my drive causing me to after reformat it. That is why there is a debugging mode in the driver now. The problem was fixed and this version seems to be working to me.

 BUILD   nasm -f bin ch376dos.asm -o ch376dos.sys
;
; CONFIG.SYS
;   DEVICE=C:\CH376\CH376DOS.SYS @260 #0 %2 + 
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
