;; UC.ASM      -> Uncompress ACOMP compressed audio data.
;;            Written by John W. Ratcliff, 1991.
	.model	small
	jumps
	.stack	300h

ShiftR	macro REG,TIMES
;; 2 - shift a register right a number of times.
        REPT    TIMES
	shr	REG,1
	ENDM
endm

ShiftL  macro REG,TIMES
;; 3 - shift a register left a number of times
        REPT    TIMES
	shl	REG,1
        ENDM
endm

PENTER  macro STORAGE
;; 17 - Enter a procedue with storage space
;; Procedure enter, uses the 286/386 ENTER opcode
        push    bp
        mov     bp,sp
        IF      STORAGE
        sub     sp,STORAGE
ENDIF
endm

PLEAVE	macro
;; 18 - Exit a procedure with stack correction.
        mov     sp,bp
        pop     bp
endm

PushCREGS	macro
;; 19 - Save registers for C
        push    es
	push	ds   ;The Kernel is responsible for maintaining DS
        push    si
        push    di
        cld
endm

PopCREGS	macro
;; 20 - Restore registers for C
        pop     di
        pop     si
	pop	ds ;The Kernel is responsible for maintaining DS
        pop     es
endm

_VARS segment

infile		db 40 dup(?)
outfile		db 40 dup(?)

inlen dw ?
outlen dw ?	

start_message	db 'ACOMP Uncompressor',0dh,0ah
		db 'by John W. Ratcliff, 1991',0dh,0ah
		db 'DOS port by Serhii Liubshin, 2023',0dh,0ah
		db '$'

no_params	db 'Usage: uc.exe input_file output_file', 0dh,0ah
		db '$'

load_msg	db 'Error loading file', 0dh,0ah,'$'
save_msg	db 'Error saving file', 0dh,0ah,'$'

done_msg	db 'Done.', 0dh,0ah,'$'

;   	fileName    db "out.acp", 0
;IBUF	label
;	include floppy.inc
;	OBUF	db 20000 dup (?)
ends

_INP	segment 
InBuf	db 65535 dup (?)
ends

_OUT	segment
OutBuf	db 65535 dup (?)
ends

.code

SQLCH   equ   64      ; Squelch byte flag
RESYNC   equ   128      ; Resync byte flag.

DELTAMOD equ   00110000b   ; Bit mask for delta mod bits.

ONEBIT   equ   00010000b   ; Bit pattern for one bit delta mod.
TWOBIT   equ   00100000b   ; Bit pattern for two bit delta mod.
FOURBIT equ   00110000b   ; Bit pattern for two bit delta mod.

TRANS   db   -8,-7,-6,-5,-4,-3,-2,-1,1,2,3,4,5,6,7,8
   db   -16,-14,-12,-10,-8,-6,-4,-2,2,4,6,8,10,12,14,16
   db   -24,-21,-18,-15,-12,-9,-6,-3,3,6,9,12,15,18,21,24
   db   -32,-28,-24,-20,-16,-12,-8,-4,4,8,12,16,20,24,28,32
   db   -40,-35,-30,-25,-20,-15,-10,-5,5,10,15,20,25,30,35,40
   db   -48,-42,-36,-30,-24,-18,-12,-6,6,12,18,24,30,36,42,48
   db   -56,-49,-42,-35,-28,-21,-14,-7,7,14,21,28,35,42,49,56
   db   -64,-56,-48,-40,-32,-24,-16,-8,8,16,24,32,40,48,56,64
   db   -72,-63,-54,-45,-36,-27,-18,-9,9,18,27,36,45,54,63,72
   db   -80,-70,-60,-50,-40,-30,-20,-10,10,20,30,40,50,60,70,80
   db   -88,-77,-66,-55,-44,-33,-22,-11,11,22,33,44,55,66,77,88



;; DX contains PREVIOUS.
;; AH contains bit mask being rotated out.
;; BX up/down 1 bit value.
Delta1 macro
   LOCAL   @@UP,@@STORE
   shl   ah,1   ; Rotate bit mask out.
   jc   @@UP
   sub   dx,bx
   jns   @@STORE
   xor   dx,dx   ; Zero it out.
   jmp short @@STORE
@@UP:   add   dx,bx
   or   dh,dh
   jz   @@STORE
   mov   dx,255
@@STORE:mov   al,dl      ; Store result.
   stosb
   endm

;; BX-> base address of translate table.
;; DX-> previous.
;; AL-> index.
DeModulate macro
   LOCAL   @@HIGH,@@OK
   xlat   ; Translate into lookup table.
   cbw      ; Make it a signed word.
   add   dx,ax   ; Do word sized add, into previous.
   jns   @@HIGH
   xor   dx,dx   ; Underflowed.
@@HIGH: or   dh,dh   ; Did it overflow?
   jz   @@OK
   mov   dx,255   ; Maxed out.
@@OK:   mov   al,dl
   stosb
   endm


;;unsigned int     far UnCompressAudio(unsigned char far *source,unsigned char far *dest);
;; UnCompressAudio will decompress data which was compressed using ACOMP
;; into the destination address provided.  UnCompressAudio returns the
;; total size, in bytes, of the uncompressed audio data.
UnCompressAudio proc near
   ARG   SHAN:DWORD,DHAN:DWORD
   LOCAL   SLEN:WORD,FREQ:WORD,FRAME:WORD,BITS:WORD = LocalSpace
   PENTER   LocalSpace
   PushCREGS

   lds   si,[SHAN]      ; Get source segment
   les   di,[DHAN]      ; Get destination segment

   lodsw            ; Get length.

   ;mov	ax,100h


   mov   [SLEN],ax      ; Save length.
   mov   cx,ax         ; Into CX
   lodsw            ; Frequency.
   mov   [FREQ],ax      ; Save frequency
   lodsb            ; Get frame size.
   xor   ah,ah         ; Zero high byte
   mov   [FRAME],ax      ; Save it.
   lodsb            ; Get squelch, and skip it.
   lodsw            ; Get maximum error, and skip it.
   lodsb            ; Get initial previous data point.
   stosb            ; Store it.
   xor   ah,ah         ; zero high byte.
   mov   dx,ax      ; Save into previous word.
   dec   cx      ; Decrement total by one.
   jz   @@DONE      ; Exit
   mov   ah,al      ; AH, always the previous.
@@DCMP: lodsb         ; Get sample.
   test   al,RESYNC   ; Resync byte?
   jz   @@NOTR      ; no, skip.
   shl   al,1      ; Times two.
   mov   dl,al      ; Into previous.
   xor   dh,dh      ; Zero high word.
   stosb         ; Store it.
   loop   @@DCMP      ; Next one.
   jmp   @@DONE

@@NOTR: test   al,SQLCH   ; Squelch byte?
   jz   @@FRAM      ; no, then it is a frame.
   and   al,00111111b   ; Leave just the count.
   push   cx      ; Save current countdown counter.
   mov   cl,al      ; get repeat count
   xor   ch,ch      ; zero high byte of CX
   mov   bx,cx      ; Repeat count in DX
   mov   al,dl      ; Repeat of previous.
   rep   stosb      ; Repeat it.
   pop   cx      ; Get back remaining count.
   sub   cx,bx      ; Less.
   ;check over
   jc	 @@DONE

   jnz   @@DCMP      ; Keep going.
   jmp   @@DONE

@@FRAM:
   mov   bx,ax      ; command byte into BX
   and   bx,0Fh      ; Multiplier being used.
   ShiftL   bx,4      ; Times 16.
   add   bx,offset TRANS ; Plus address of translate table.
   and   al,DELTAMOD   ; Leave just delta mod.
   push   cx
   mov   cx,[FRAME]   ; Get frame size.
   cmp   al,ONEBIT   ; In one bit delta mod?
   jne   @@NEXT1    ; no, try other.
   ShiftR   cx,3      ; /8
   mov   bl,cs:[bx+8]   ; Get up amount
   xor   bh,bh      ; Zero high byte.
@@GO:   lodsb
   xchg   al,ah      ; Place prev in AL, Bit mask in AH
   Delta1
   Delta1
   Delta1
   Delta1
   Delta1
   Delta1
   Delta1
   Delta1
   mov   ah,al
   loop   @@GO
   jmp   @@RENTER

@@NEXT1:cmp   al,TWOBIT   ; In two bit delta mod mode?
   jne   @@NEXT2
   add   bx,6      ; Point at +- 2 bit's in table.
   shr   cx,1
   shr   cx,1      ; 4 samples per byte.
@@GOGO: lodsb
   ShiftR   al,6
   DeModulate
   mov   al,ds:[si-1]
   ShiftR   al,4
   and   al,3
   DeModulate
   mov   al,ds:[si-1]
   ShiftR   al,2
   and   al,3
   DeModulate
   mov   al,ds:[si-1]
   and   al,3
   DeModulate
   loop   @@GOGO
   jmp short @@RENTER
@@NEXT2:shr   cx,1      ; Two samples per byte.
@@GO2:   lodsb         ; Get sample.
   ShiftR   al,4
   DeModulate
   mov   al,ds:[si-1]
   and   al,0Fh
   DeModulate
   loop   @@GO2

@@RENTER:
   pop   cx
   sub   cx,[FRAME]
   jc	 @@DONE
   jnz   @@DCMP      ; Continue decompress

@@DONE:
   mov   ax,[SLEN]   ; Uncompressed length.

   PopCREGS
   PLEAVE
   ret
   endp


skip_spaces	macro
local	@@skipb
@@skipb:
	lodsb
	sub	bp,1
	js	end_cmd_process
	cmp	al,20h ;' '
	jz	@@skipb
	cmp	al,0Dh
	jz	end_cmd_process
endm

put_chars macro
local	@@next, @@fin
	mov	cx,40
@@next:
	stosb
	lodsb
	sub	bp,1	
	js	@@fin
	cmp	al,20h
	jz	@@fin
	cmp	al,0Dh
	jz	@@fin
	loop	@@next
@@fin:  
	xor	al,al
	stosb	
endm


begin:

	mov	ax,_VARS
	mov	ds,ax

assume ds:_VARS

	mov	dx, offset start_message
	mov	ah, 9 ; Print string function
	int	21h


	cld
	push	es
	pop	ds

	mov	ax,_VARS
	mov	es,ax

	mov	si,80h
	xor	ax,ax
	lodsb
	;bp	will be our counter
	mov	bp,ax
	test	bp,bp
	jz	show_pars

	mov	di,offset infile
	skip_spaces	
	put_chars
	mov	al,es:[infile]
	cmp	al,0
	jz	show_pars

	mov	di,offset outfile
	skip_spaces	
	put_chars
	mov	al,es:[outfile]
	cmp	al,0
	jz	show_pars	
	jmp	end_cmd_process

show_pars:
;Show usage and exit
	mov	ax,_VARS
	mov	ds,ax

	mov	dx,offset no_params
	mov	ah,9
	int	21h

	mov	ax,4C01h
	int	21h

end_cmd_process:

	mov	ax,_VARS
	mov	ds,ax

	mov	al,es:[infile]
	cmp	al,0
	jz	show_pars

	mov	al,es:[outfile]
	cmp	al,0
	jz	show_pars

;Load file
	mov	ah,3Dh         ; Function 3Dh - Open file
	mov	al,0           ; Open for reading
	mov	dx,offset infile ; Pointer to filename
	int	21h
	jc	load_error

	mov	bx,ax ; BX holds the file handle

	push	ds
	mov	ax,_INP
	mov	ds,ax
	xor	dx,dx

	mov	ah,3Fh         ; Function 3Fh - Read file
	mov	cx,65535
	int	21h

	pop	ds

	jnc	load_ok                                                 

load_error:
	mov	dx,offset load_msg
	mov	ah,9
	int	21h

	mov	ax,4C01h
	int	21h

load_ok:
	mov	[inlen],ax
	mov	ah,3Eh         ; Function 3Eh - Close file
	int	21h


	mov	ax,_OUT
	push	ax
	xor	ax,ax
	push	ax

	mov	ax,_INP
	push	ax
	xor	ax,ax
	push	ax

	call	UnCompressAudio

	mov	[outlen],ax

;Write file
	mov	ah,3Ch         
	mov	dx,offset outfile ; Pointer to filename
	int	21h
	jc	write_error

	mov	bx,ax ; BX holds the file handle

	mov	cx,[outlen]
	push	ds
	mov	ax,_OUT
	mov	ds,ax
	xor	dx,dx

	mov	ah,40h 
	int	21h

	pop	ds

	jnc	write_ok                                                 

write_error:
	mov	dx,offset save_msg
	mov	ah,9
	int	21h

	mov	ax,4C01h
	int	21h

write_ok:
	mov	ah,3Eh         ; Function 3Eh - Close file
	int	21h

	mov	dx,offset done_msg
	mov	ah,9
	int	21h

	mov	ax,4C00h
	int	21h

	end	begin