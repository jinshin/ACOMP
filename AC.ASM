;; AC.ASM -> ACOMP assembly language compressor. Written by John W. Ratcliff,
;; 1991. Uses Turbo Assembler IDEAL mode and makes HEAVE use of macros. This
;; algorithm performs an exhaustive search for the best delta mod for each
;; section of the waveform. It is very CPU intensive, and the algorithm can
;; be a little difficult to follow in assembly language.

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

    ;SQUELCH:WORD,FREQ:WORD,FRAME:WORD,MAXERR:WORD
num_squelch	dw 18
num_freq	dw 18356
num_frame	dw 64
num_maxerr	dw 8

start_message	db 'ACOMP: Compressor for 8-bit audio',0dh,0ah
		db 'by John W. Ratcliff, 1991',0dh,0ah
		db 'DOS port by Serhii Liubshin, 2023',0dh,0ah
		db '$'

no_params	db 'Usage: ac.exe input_file output_file [Freq Frame Squelch MaxErr]', 0dh,0ah
	 	db 'Freq: frequency of input file. Input must be mono 8 bit raw file', 0dh,0ah
		db 'Frame: processing chuck size', 0dh,0ah
		db 'Squelch: silence compression strengh', 0dh,0ah
		db 'MaxErr: max delta error allowed', 0dh,0ah
		db 'Default values: 18356 64 18 8',0dh,0ah
		db '$'

load_msg	db 'Error loading file', 0dh,0ah,'$'
save_msg	db 'Error saving file', 0dh,0ah,'$'

done_msg	db 'Done.',0dh,0ah,'$'
abort_msg	db 'Aborted.',0dh,0ah,'$'
proc_msg	db 'Compressing, press ESC to abort',0dh,0ah,'$'

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
;; This macro echos a message to the text screen, so that we can
;; monitor the progress of the compression algorithm.
Note	macro MSG
    push si
    mov si,offset MSG
    call    Notify
    pop si
    endm

msg0    db  "SQUELCH"
msg1    db  "RESYNC "
msg2    db  "1 BIT  "
msg3    db  "2 BIT  "
msg4    db  "4 BIT  "

Notify  proc near
    push ax cx di es ds

    push cs
    pop ds
    mov ax,0B800h
    mov es,ax
    xor di,di
    mov ah,1Fh
    mov cx,7
@@SND:  lodsb
    stosw
    loop    @@SND

    pop ds es di cx ax
    ret
    endp


;; This macro computes the amount of error in a frame of data, at this
;; bit resolution and this delta mod location.
DoError	macro BITS
    LOCAL   @@NO
    mov bx,[COMP]       ; Current delta mod value.
    mov bh,BITS         ; Current bit resolution.
    push    [MINERR]        ; Pass minimum error so far.
    push    [PREV]          ; Pass previous data point.
    call    ComputeError        ; Compute error for frame.
    add sp,4            ; Balance stack.
    cmp dx,[MINERR]     ; Less than previous minimum?
    jge @@NO            ; no, don't update.
    mov [MINERR],dx     ; Save as new miniume
    mov [BESTPREV],ax       ; Best previous location.
    xor ah,ah           ;
    mov al,bl           ; Get best delta modution.
    mov [BEST1],ax      ; save it.
    mov al,bh           ; Get best bits.
    mov [BEST2],ax      ; Save it.
@@NO:
    endm


SQLCH   equ 64      ; Squelch bit.
RESYNC  equ 128     ; Resynchronization bit.

DELTAMOD equ    00110000b   ; Bit mask for delta mod bits.

ONEBIT  equ 00010000b   ; Bit pattern for one bit delta mod.
TWOBIT  equ 00100000b   ; Bit pattern for two bit delta mod.
FOURBIT equ 00110000b   ; Bit pattern for two bit delta mod.

;;This the the ACOMP compression procedure.
;;int far CompressAudio(unsigned char far *shand,
;;                                           Address of audio data to compress.
;;          unsigned char far *dhand,
;;                                      Destination address of compressed data.
;;          unsigned int slen, Length of audio data to compress.
;;          int squelch,       Squelch value allowed.
;;          int freq,      Playback frequency of audio data.
;;          int frame,     Frame size.
;;          int maxerr);       Maximum error allowed.
_CompressAudio  proc near
    ARG     SHAN:DWORD,DHAN:DWORD,SLEN:WORD,SQUELCH:WORD,FREQ:WORD,FRAME:WORD,MAXERR:WORD
    LOCAL   PREV:WORD,COMP:WORD,MINERR:WORD,BEST1:WORD,BEST2:WORD,BESTPREV:WORD = LocalSpace
    PENTER  LocalSpace
    PushCREGS

    lds si,[SHAN]       ; Get source address.
    les di,[DHAN]       ; Get destination address.
    mov cx,[SLEN]       ; Get length of audio data.

    mov ax,cx       ; Get length of audio sample into AX
    stosw           ; Store it.
    mov ax,[FREQ]   ; Get frequency of recording.
    stosw           ; Store it.
    mov ax,[FRAME]  ; Get the frame size.
    stosb           ; Store it.
    mov ax,[SQUELCH]    ; Get squelch size
    stosb           ; Store it.
    mov ax,[MAXERR] ; Get maximum error allowed.
    stosw           ; Save it.
    xor ax,ax
    lodsb           ; Get first data sample
    mov [PREV],ax
    stosb           ; Store first data sample.
    dec cx      ; Decrement sample size count.
    jz  @@DONE

@@SQU:  mov ah,0Bh      ; Test keyboard status.
    int 21h
    or  al,al
    jz  @@NOK
    mov ah,08h      ; If a key was pressed get that key
    int 21h     ; value, and see if it was the
    cmp al,27       ; escape key.
    jne @@NOK
    xor ax,ax       ; If escape, return to caller, with abort.
    jmp @@EXIT
@@NOK:
    xor ax,ax
    mov dx,[SQUELCH]    ; Get squelch value.
    push    cx      ; Save remaining data count.
    push    si      ; Save si.
@@CK1:  lodsb           ; Get data byte.
    sub ax,[PREV]   ; Difference from previous data sample?
    jns @@CK2       ; if positive leave it alone.
    neg ax      ; Make it positive.
@@CK2:  cmp ax,dx       ; Is it within the squelch range?
    jg  @@NOS       ; yes, keep checking!
    loop    @@CK1       ; Keep going.
    inc si      ; Plus one, this last one counts.
@@NOS:  pop ax      ; Get back start SI
    mov dx,si       ; DX contains current address.
    sub dx,ax       ; Compute number of squelch bytes encountered.
    dec dx      ; Less, last non squelch byte.
    cmp dx,3        ; At least three?
    jle @@NOSQ      ; no, don't squelch it.
@@SQS:  cmp dx,63       ; Is it under 63?
    jle @@SEND
    mov ax,(63 + SQLCH)  ; Send count.
    sub dx,63       ; Less the 63 count we just sent.
    stosb           ; Write squelch byte out.
    jmp short @@SQS     ; Continue.
@@SEND: mov ax,dx       ; Get remaining count.
    or  ax,SQLCH    ; Or squelch bit on.
    stosb           ; Send squelch count out.
    dec si      ; Back up to last data point.
    pop ax      ; Pull CX off of stack, use current count.
    Note    msg0
    jmp short @@NXT
@@NOSQ: mov si,ax       ; Replace where source was.
    pop cx      ; Get back remaining data count.

@@NXT:  jcxz    @@DONE      ; Exit if done.
    cmp cx,[FRAME]  ; Below current frame size?
    jae @@GO        ; no, go ahead.
@@FIN:  lodsb           ; Get raw sample.
    shr al,1        ; Down to closest aproximated value.
    or  al,RESYNC   ; Add resync bit to it.
    stosb           ; Store out.
    loop    @@FIN       ; Keep sending final bytes.
    jmp @@DONE      ; exit, after sending final bytes.

@@GO:   mov [MINERR],07FFFh
    push    cx
    mov cx,[FRAME]  ; Set CX to frame size.

    mov [COMP],1
@@ALL1: DoError 1       ; Try one bit mode, +/-1.
    inc [COMP]
    cmp [COMP],17   ; Try delta comp values clean up to 16!!
    jne @@ALL1

    mov ax,[MINERR]
    cmp ax,[MAXERR]
    jle @@BCMP      ; Not good enough...
    mov [COMP],1
@@ALL2: DoError 2       ; Try two bit mode, +/-1.
    inc [COMP]
    cmp [COMP],17   ; Try delta comp values clean up to 16!!
    jne @@ALL2

    mov ax,[MINERR]
    cmp ax,[MAXERR]
    jle @@BCMP
    mov [COMP],1
@@ALL4: DoError 8       ; Try four bit mode, +/-1.
    inc [COMP]
    cmp [COMP],17   ; Try delta comp values clean up to 16!!
    jne @@ALL4

    mov ax,[MINERR] ; Get what the minimum error was.
    cmp ax,[MAXERR] ; Minimum error > maximum error?
    jle @@BCMP      ; no, then send frame.
    pop cx      ; Get back CX
    lodsb           ; Get data sample.
    and al,(NOT 1)  ; Strip off bottom bit.
    xor ah,ah
    mov [PREV],ax   ; New previous.
    shr al,1        ; /2
    or  al,RESYNC   ; Or resync bit on.
    stosb           ; Store it out into data stream.
    Note    msg1
    loop    @@SQU       ; Go check squelching.
    jmp @@DONE      ; Done, if this was last data sample.
@@BCMP: mov bx,[BEST1]  ; Get best comp.
    mov ax,[BEST2]  ; Get best bit size.
    mov bh,al       ; Into BH
    mov ax,32000
    push    ax
    push    [PREV]      ; Pass prev.
    call    ComputeError    ; Re-compute error term.
    add sp,4
    mov [PREV],ax   ; New previous.
;; Now time to store results!
    mov bx,[BEST1]  ; Get best comp.
    cmp [BEST2],1   ; 1 bit?
    jne @@NXT1
    call    Fold1Bit    ; Fold 1 bit data.
    Note    msg2
    jmp short @@IN      ; Reenter.
@@NXT1: cmp [BEST2],2   ; 2 bit data?
    jne @@NXT2
    call    Fold2Bit
    Note    msg3
    jmp short @@IN
@@NXT2:
    call    Fold4Bit
    Note    msg4
@@IN:   mov ax,[FRAME]
    pop cx      ; Get back CX
    add si,ax       ; Advance source
    sub cx,ax       ; Decrement data count.
    jnz @@SQU       ; Continue, if not at end.

@@DONE:
    mov ax,di       ; Size of compressed file.
    les di,[DHAN]
    sub ax,di       ; Difference.

@@EXIT:
    PopCREGS
    PLEAVE
    ret
    endp


;; Compute error:  Registers on entry are:
;;         DS:SI -> source data.
;;         CX    -> number of bytes to compute error term in.
;;         DX    -> total error incurred.
;;         BL    -> delta comp size.
;;         BH    -> maximum bit size value, positive or negative.
;; Exit: CX,DS:SI stay the same.
;;   DX -> total error term.
;;   AX -> new previous.
ComputeError    proc near
    ARG PREV:WORD,MINERR:WORD
    LOCAL   CUR:WORD = LocalSpace
    PENTER  LocalSpace

    push    cx
    push    si
    push    di      ; Save destination address.
    xor dx,dx       ; Initally no error.

@@CERR: lodsb           ; Get a data byte.
    xor ah,ah       ; Zero high byte.
    mov [CUR],ax    ; Save as current sample.
    sub ax,[PREV]
    cmp bl,1
    je  @@ND
    idiv    bl      ; Divided by delta mod size.
@@ND:   or  al,al
    js  @@DON       ; Do negative side.
    jnz @@CNT       ; If not zero then continue.
    inc al      ; Can't represent a zero, make it one.
@@CNT:  cmp al,bh       ; > max representative size?
    jle @@OK        ; no, it fit as is.
    mov al,bh       ; Make it the max representative size.
    jmp short @@OK      ;
@@DON:  neg al      ; Make it positive.
    cmp al,bh       ; > max representative size?
    jbe @@K2        ; no, use it.
    mov al,bh       ; Make it the max representative size.
@@K2:   neg al      ; Make it negative again.
@@OK:
    stosb           ; Store data value out.
    imul    bl      ; Times delta comp value.
    add ax,[PREV]   ; Add to previous data point.
    js  @@CS        ; Do signed case.
    cmp ax,255      ; Did it over flow?
    jle @@K3        ; No, then it fit byte sized.
    mov ax,255      ; Make it byte sized.
    jmp short @@K3      ; Re-enter
@@CS:   xor ax,ax       ; Close as we can get, underflow.
@@K3:   mov [PREV],ax   ; This is our new aproximated value.
    sub ax,[CUR]    ; Less actual value.
    jns @@K4        ; if positive then fine.
    neg ax      ; Take absolute value.
@@K4:   add dx,ax       ; Add into total error.
    cmp dx,[MINERR] ; Greater than minimum error allowed?
    jg  @@OUT
    loop    @@CERR
@@OUT:  mov ax,[PREV]   ; Current previous data point.
    pop di      ; Restore destination address.
    pop si      ; Reset SI back to start.
    pop cx      ; Reset CX back to start.
    PLEAVE
    ret
    endp


BuildByte macro
    LOCAL   @@HOP1,@@HOP2
    lodsb
    or  al,al       ; Is it signed?
    jns @@HOP1
    shl ah,1        ; Rotate.
    jmp short @@HOP2
@@HOP1: stc
    rcl ah,1
@@HOP2:
    endm
;; Fold 1 bit data.
;; ES:DI -> points to data ready to fold out.
;; CX-> frame size.
;; BL-> contains delta size.
Fold1Bit    proc near
    push    ds
    push    si
    push    di      ; Header byte address.
    push    es
    pop ds      ; DS=ES
    mov si,di       ; Source and dest.
    inc di      ; skip past header byte.
@@FOLD: xor ah,ah       ; Dest byte to be built, zero it.
    BuildByte
    BuildByte
    BuildByte
    BuildByte
    BuildByte
    BuildByte
    BuildByte
    BuildByte
    mov al,ah
    stosb           ; Store it out.
    sub cx,8        ; Less the 8 samples just folded up.
    jnz @@FOLD      ; Continue.

    pop si      ; Get back header byte address.
    mov al,bl       ; Get delta comp size.
    dec al      ; Less one.
    or  al,ONEBIT   ; Or the One Bit mode flag on.
    mov ds:[si],al  ; Store header byte.

    pop si
    pop ds
    ret
    endp

;; 2 Bit Format:  00 -> -2
;;        01 -> -1
;;        10 -> +1
;;        11 -> +2
BByte	macro
    LOCAL   @@HOP1,@@HOP2
    lodsb
    or  al,al       ; Is it signed?
    jns @@HOP1
    add al,2        ; Adjust it.
    jmp short @@HOP2
@@HOP1: inc al      ; Plus 1 to fit into format size.
@@HOP2: shl ah,1
    shl ah,1
    or  ah,al       ; Place bits into byte being built.
endm

;; Fold 2 bit data.
;; ES:DI -> points to data ready to fold out.
;; CX-> frame size.
;; BL-> contains delta size.
Fold2Bit    proc near
    push    ds
    push    si
@@F2:
    push    di      ; Header byte address.

    push    es
    pop ds      ; DS=ES
    mov si,di       ; Source and dest.
    inc di      ; skip past header byte.
@@FOLDA:
    xor ah,ah       ; Dest byte to be built, zero it.
    BByte
    BByte
    BByte
    BByte
    mov al,ah
    stosb           ; Store it out.
    sub cx,4        ; Folded up 4 samples.
    jnz @@FOLDA      ; Continue.

    pop si      ; Get back header byte address.
    mov al,bl       ; Get delta comp size.
    dec al      ; Less one.
    or  al,TWOBIT   ; Or the One Bit mode flag on.
    mov ds:[si],al  ; Store header byte.

    pop si
    pop ds
    ret
    endp

;; Four bit format:
;; 0 -> -8
;; 1 -> -7
;; 2 -> -6
;; 3 -> -5
;; 4 -> -4
;; 5 -> -3
;; 6 -> -2
;; 7 -> -1
;; 8 -> +1
;; 9 -> +2
;;10 -> +3
;;11 -> +4
;;12 -> +5
;;13 -> +6
;;14 -> +7
;;15 -> +8
Adjust4bit macro
    LOCAL   @@HOP1,@@HOP2
    lodsb
    or  al,al
    jns @@HOP1
    add al,8        ; Adjust it.
    jmp short @@HOP2
@@HOP1: add al,7        ; Adjust it.
@@HOP2:
endm

;; Fold 4 bit data.
;; ES:DI -> points to data ready to fold out.
;; CX-> frame size.
;; BL-> contains delta size.
Fold4Bit    proc near
    push    ds
    push    si

    push    di      ; Header byte address.

    push    es
    pop ds      ; DS=ES
    mov si,di       ; Source and dest the same.
    inc di      ; skip past header byte.
@@FOLDB:
    Adjust4bit      ; Get first sample.
    ShiftL  al,4        ; Into high nibble.
    mov ah,al       ; Into AH
    Adjust4bit      ; Get next nibble.
    or  al,ah       ; One whole byte.
    stosb           ; Store it out.
    sub cx,2        ; Folded up 4 samples.
    jnz @@FOLDB     ; Continue.

    pop si      ; Get back header byte address.
    mov al,bl       ; Get delta comp size.
    dec al      ; Less one.
    or  al,FOURBIT  ; Or the One Bit mode flag on.
    mov ds:[si],al  ; Store header byte.

    pop si
    pop ds
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

get_number	proc
	xor	bx,bx
	xor	ah,ah
	mov	cx,5

next_c:
	cmp	al,30h
	jb	wrong_n
	cmp	al,39h
	ja	wrong_n
	sub	al,30h
	
	push	ax
	mov	ax,bx
	mov	dx,10
	mul	dx
	mov	bx,ax
	pop	ax
	add	bx,ax	

	lodsb
	sub	bp,1	
	js	finall_
	cmp	al,20h
	jz	fin_
	cmp	al,0Dh
	jz	finall_
	loop	next_c

finall_:
	mov	bp,0FFFFh
fin_:
	mov	ax,bx
	ret

wrong_n:
	mov	ax,0FFFFh
	ret
endp

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

;Numbers	
	skip_spaces
	call	get_number
	cmp	ax,0FFFFh
	je	end_cmd_process
	mov	es:[num_freq],ax
	cmp	bp,0FFFFh
	je	end_cmd_process		

	skip_spaces
	call	get_number
	cmp	ax,0FFFFh
	je	end_cmd_process
	mov	es:[num_frame],ax
	cmp	bp,0FFFFh
	je	end_cmd_process		

	skip_spaces
	call	get_number
	cmp	ax,0FFFFh
	je	end_cmd_process
	mov	es:[num_squelch],ax
	cmp	bp,0FFFFh
	je	end_cmd_process		

	skip_spaces
	call	get_number
	cmp	ax,0FFFFh
	je	end_cmd_process
	mov	es:[num_maxerr],ax
	cmp	bp,0FFFFh
	je	end_cmd_process		


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

	mov	dx,offset proc_msg
	mov	ah,9
	int	21h

process:

        mov	ax,_VARS
        mov	ds,ax

	mov	ax,[num_maxerr]     ;Error
	push	ax

	mov	ax,[num_frame]    ;Frame
	push	ax

	mov	ax,[num_freq] ;Freq
	push	ax

	mov	ax,[num_squelch]    ;Squelch
	push	ax

	mov	ax,[inlen]  ;length
	push	ax

	mov	ax,_OUT
	push	ax
	xor	ax,ax
	push	ax

	mov	ax,_INP
	push	ax
	xor	ax,ax
	push	ax

	call _CompressAudio

	test	ax,ax
	jnz	processed

	mov	dx,offset abort_msg
	mov	ah,9
	int	21h

	mov	ax,4C01h
	int	21h	

processed:
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

	end begin