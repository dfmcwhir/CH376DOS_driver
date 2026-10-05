# CH376DOS_driver
CH376DOS mass storage usb driver for DOS


DOS Driver for the CH376 chip to enable usb mass storage. Made using AI, may have bugs, may corrupt your drive, use with caution! It does work for me on an ISA card with a CH376 module on it addressed at a base address of 260h. I successfully did read and writes a 1GB thumb drive formatted as FAT in non-interrupt mode. No speed or other testing has been done

While working with AI to create this driver, the initial versions would fail to write to the drive and also led to corruption on my drive causing me to have to reformat it. That is why there is a debugging mode in the driver now. The problem was fixed and this version seems to be working to me.

BUILD:   nasm -f bin ch376dos.asm -o ch376dos.sys <br>
<br>
Usage: <br>
CONFIG.SYS<br>
DEVICE=C:\CH376\CH376DOS.SYS @260 #0 %2 +<br><br>
 @hhh = I/O base address in HEX (default 260). <br>
         base+0 = CH376 data port, base+1 = CH376 command/status port<br>
         (CH376 A0 pin wired to ISA A0).  Change CMD_OFS below if your card<br>
         maps the command port somewhere else.<br><br>
   #n = IRQ number 3..7 (decimal).  <br>
			      0 / omitted = no interrupt, the driverpolls the chip.  With an IRQ the driver sleeps (HLT) during the long<br>
         waits (connect / mount); it still polls the chip's INT flag, so a<br>
         wrongly wired IRQ costs only speed, never correctness.<br><br>
   ! = debug: <br>
			      on a failed read/write, print a one-line report (status code,<br>
         byte count, LBA) with BIOS INT 10h.  Use it when tracking problems.<br><br>
   + = enable WRITES.<br>
									Without it the drive is read-only (DOS reports a <br>
         write-protect error), which is the safe default while testing. <br><br>
   &n= experiment: <br>
       wait n BIOS ticks (55 ms each) after every sector written.<br><br>
   %n=speed modifier<br>
			      The CH376 needs a short recovery time between bus<br>
         accesses; the driver inserts a delay loop of 48/n iterations after<br>
         each write.  %0 / %1 = longest delay (use on FAST machines);<br>
         larger values = shorter delay (use on SLOW machines, e.g. %16 on a<br>
         4.77 MHz XT).  If you get random read/write errors, lower n.<br><br>
<br>
 WHAT IT DOES<br>
   * One removable drive.  Only the first FAT12/FAT16 partition of an MBR<br>
     disk is used (or a "super-floppy" with no partition table).<br>
   * 512-byte sectors, up to 32-bit sector numbers (DOS 3.31+ big volumes).<br>
   * Hot-swap: media change is detected via the CH376 connect/disconnect<br>
     events, DOS then re-reads the BPB.<br>
   * Uses CH376 sector commands DISK_READ / DISK_WRITE (one sector per<br>
     command) after DISK_CONNECT + DISK_MOUNT (or DISK_INIT/READY when the<br>
     volume is not a file system the chip understands).<br>
   * Only 8086 instructions are used.<br>

NOT SUPPORTED: FAT32, exFAT, NTFS, more than one LUN, 2048/4096-byte <br>
 sectors, DOS generic IOCTL.<br>
