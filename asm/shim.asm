; K5 CP/M shim (radio86rk-contracts.md): warm boot, BDOS entry, handler.
; Console: OUT 0x01. Unsupported BDOS function: OUT 0xFE. Exit: OUT 0xFF.
	cpu	8080

	org	0000h
	out	0ffh		; warm boot: end of run
	hlt

	org	0005h
	jmp	0fe00h		; BDOS entry

	org	0fe00h
	mov	a,c
	cpi	2
	jz	putc
	cpi	9
	jz	puts
	out	0feh
	ret
putc:	mov	a,e
	out	01h
	ret
puts:	ldax	d
	cpi	'$'
	rz
	out	01h
	inx	d
	jmp	puts
