;;;
;;; A Fuzix booter for the multicomp09 SDcard controller.
;;;
;;; Neal Crook April 2016
;;; This code started as a frankensteinian fusion of Brett's Coco3
;;; booter and my FLEX bootstrap loader.
;;;
;;; The booter is contained within a single 512-byte sector and is
;;; formatted like a standard MSDOS master boot record (MBR) -- except
;;; that the code is 6809 and not position-independent.
;;;
;;; An MBR is intended to go in sector 0 but I cannot easily arrange
;;; that on my SD and so I have placed it elsewhere -- and added an
;;; option to the FUZIX MBR parser to look for it at an arbitrary
;;; location. The partition data in the MBR is still absolute, though;
;;; *not* relative to the location of the MBR.
;;;
;;; The booter (the whole MBR) can live anywhere on the SD. It is loaded
;;; to 0xd000 and entered from there -- the load address is chosen simply
;;; to avoid the kernel; it may change in future if I adjust the memory
;;; map.
;;;
;;; The booter uses a 512byte disk buffer beyond its end point and a small
;;; 100-byte stack beyond that.. so its whole footprint is just >1Kbyte.
;;;
;;; Environment: at entry, the multicomp ROM is disabled and the
;;; MMU is enabled and is set up for a flat (1-1) mapping, with TR=0.
;;; Function: load and start a DECB image (the FUZIX kernel). The
;;; location of the image on the SDcard is hard-wired by equates
;;; klba2..klba0 below.

;;; [NAC HACK 2016Apr22] todo: don't actually NEED a disk buffer..
;;; do without it.. but then need a routine to flush the remaining
;;; data (if any) from the SDcard after the last sector's done
;;; with and before jumping into the loaded image. Then, put the stack
;;; within the footprint, too, as there's plenty of room.

;;; --------- multicomp i/o registers

;;; sdcard control registers
sddata	equ $ffd8
sdctl	equ $ffd9
sdlba0	equ $ffda
sdlba1	equ $ffdb
sdlba2	equ $ffdc

;;; vdu/virtual UART
uartdat	equ $ffd1
uartsta	equ $ffd0

klba2	equ $3
klba1	equ $0
klba0	equ $0

;;; based on the memory map, this seems a safe place to load; the
;;; kernel doesn't use any space here. That may change and require
;;; a re-evaluation.
start   equ $d000


	org	start

;;; entry point
	lds	#stack

	lda	#'F'		; show user that we got here
	bsr	tovdu
	lda	#'U'
	bsr	tovdu
	lda	#'Z'
	bsr	tovdu
	lda	#'I'
	bsr	tovdu
	lda	#'X'
	bsr	tovdu

;;; decb format:
;;;
;;; section preamble:
;;; offset 0 0x00
;;;	   1 length high
;;;	   2 length low
;;;	   3 load address high
;;;	   4 load address low
;;;
;;; image postamble:
;;; offset 0 0xff
;;;	   1 0x00
;;;	   2 0x00
;;;	   3 exec high
;;;	   4 exec low

;;; Y - preserved as pointer to disk buffer. Start at empty
;;; buffer to trigger a disk load.
	ldy	#sctbuf+512

c@	jsr	getb		; get a byte in A from buffer
	cmpa	#$ff		; postamble marker?
	beq	post		; yes, handle it and we're done.
	;; expect preamble
	cmpa	#0		; preamble marker?
	lbne	abort		; unexpected.. bad format
	jsr	getw		; D = length
	tfr	d,x		; X = length
	jsr	getw		; D = load address
	tfr	d,u		; U = load address
	;; load section: X bytes into memory at U
d@	jsr	getb		; A = byte
	sta	,u+		; copy to memory
	leax	-1,x		; decrement byte count
	bne	d@		; loop for next byte if any
	bra	c@		; loop for next pre/post amble
	;; postable
post	jsr	getw		; get zero's
	cmpd	#0		; test D.. expect 0
	lbne	abort		; unexpected.. bad format
	jsr	getw		; get exec address
	pshs	d		; save on stack
	rts			; go and never come back


;;; Abort! Bad record format.
abort	lda	#'B'		; show user that we got here
	bsr	tovdu
	lda	#'A'
	bsr	tovdu
	lda	#'D'
	bsr	tovdu
	lda	#$0d
	bsr	tovdu
	lda	#$0a
	bsr	tovdu
abort1	bra	abort1		; spin forever


;;;
;;; SUBROUTINE ENTRY POINT
;;; send character to vdu
;;; a: character to print
;;; can destroy b,cc

tovdu	pshs	b
vdubiz	ldb	uartsta
	bitb	#2
	beq	vdubiz	; busy

	sta	uartdat	; ready, send character
	puls	b,pc


;;;
;;; SUBROUTINE ENTRY POINT
;;; get next word from disk buffer - read sector/refill buffer
;;; if necessary
;;; return word in D
;;; must preserve Y which is a global pointing to the next char in the buffer

getw	jsr	getb		; A = high byte
	tfr	a,b		; B = high byte
	jsr	getb		; A = low byte
	exg	a,b		; flip D = next word
	rts


;;;
;;; SUBROUTINE ENTRY POINT
;;; get next byte from disk buffer - read sector/refill buffer
;;; if necessary
;;; return byte in A
;;; Destroys A, B.
;;; must preserve Y which is a global pointing to the next char in the buffer

getb	cmpy	#sctbuf+512	; out of data?
	bne	getb4		; go read byte if not
getb2	bsr	read		; read next sector, reset Y
	ldd	lba1		; point to next linear block
	addd	#1
	std	lba1
getb4	lda	,y+		; get next character
	rts


;;;
;;; SUBROUTINE ENTRY POINT
;;; read single 512-byte block from lba0, lba1, lba2 to
;;; buffer at sctbuf.
;;; return Y pointing to start of buffer.
;;; Destroys A, B
;;;

read	lda	lba0		; load block address to SDcontroller
	sta	sdlba0
	lda	lba1
	sta	sdlba1
	lda	lba2
	sta	sdlba2

	clra
	sta	sdctl		; issue RD command to SDcontroller

	ldy	#sctbuf		; where to put it

;;; now transfer 512 bytes, waiting for each in turn.

	clrb			; zero is like 256
sdbiz	lda	sdctl
	cmpa	#$e0
	bne	sdbiz		; byte not ready
	lda	sddata		; get byte
	sta	,y+		; store in sector buffer
	decb
	bne	sdbiz		; next

	;; b is zero (like 256) so ready to spin again
sdbiz2	lda	sdctl
	cmpa	#$e0
	bne	sdbiz2		; byte not ready
	lda	sddata		; get byte
	sta	,y+		; store in sector buffer
	decb
	bne	sdbiz2		; next

	lda	#'.'		; indicate load progress
	lbsr	tovdu

	ldy	#sctbuf		; where next byte will come from
	rts

;;; location on SDcard of kernel (24-bit LBA value)
;;; hack!! The code here assumes NO WRAP from lba1 to lba2.
lba2	fcb     klba2
lba1	fcb     klba1
lba0	fcb     klba0


;;; horrible fudge to compensate for assembler lackings..
	zmb	218

;;; For MBR format, see:
;;; http://wiki.osdev.org/MBR_%28x86%29
;;; http://wiki.osdev.org/Partition_Table

	org	start+$1b4
mbr_uid
	.ds	10

	org	start+$1be
mbr_0
	fcb	$80		; not bootable (ignored by FUZIX)
	fcb	$ff,$ff,$ff	; start: "max out" CHS so LBA values will be used.
	fcb	$01,$02,$03,$04	; system ID (ignored by FUZIX??)
	fcb	$ff,$ff,$ff	; end: "max out" as before
	;; 32-bit values are stored little-endian: LS byte first.
	;; 65535-block root disk at 0x0003.1000
	fcb	$00,$10,$03,$00	; partition's starting sector
	fcb	$fe,$ff,$00,$00	; partition's sector count

	org	start+$1be
mbr_1
	fcb	$80		; not bootable (ignored by FUZIX)
	fcb	$ff,$ff,$ff	; start: "max out" CHS so LBA values will be used.
	fcb	$01,$02,$03,$04	; system ID (ignored by FUZIX)
	fcb	$ff,$ff,$ff	; end: "max out" as before
	;; 32-bit values are stored little-endian: LS byte first.
	;; 65535-block additional disk at 0x0004.1000
	fcb	$00,$10,$04,$00	; partition's starting sector
	fcb	$fe,$ff,$00,$00	; partition's sector count


	org	start+$1be
mbr_2
	fcb	$80		; not bootable (ignored by FUZIX)
	fcb	$ff,$ff,$ff	; start: "max out" CHS so LBA values will be used.
	fcb	$00,$00,$00,$00	; system ID (0=> unused)
	fcb	$ff,$ff,$ff	; end: "max out" as before
	;; 32-bit values are stored little-endian: LS byte first.
	fcb	$00,$01,$02,$fc	; partition's starting sector
	fcb	$00,$01,$02,$fc	; partition's sector count


	org	start+$1be
mbr_3
	fcb	$80		; not bootable (ignored by FUZIX)
	fcb	$ff,$ff,$ff	; start: "max out" CHS so LBA values will be used.
	fcb	$00,$00,$00,$00	; system ID (0=> unused)
	fcb	$ff,$ff,$ff	; end: "max out" as before
	;; 32-bit values are stored little-endian: LS byte first.
	fcb	$00,$10,$03,$00	; partition's starting sector
	fcb	$fe,$ff,$00,$00	; partition's sector count


	org	start+$1fe
mbr_sig
	fcb	$55
	fcb	$aa

sctbuf	equ	.
	.ds	512		; SDcard sector buffer
	.ds	100		; space for stack
stack	equ	.

	end	start
