*
* asm_support.asm - AmigaOS utility functions in assembly language
*
* Basilisk II (C) 1997-1999 Christian Bauer
*
* This program is free software; you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation; either version 2 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program; if not, write to the Free Software
* Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*

		INCLUDE	"exec/types.i"
		INCLUDE	"exec/macros.i"
		INCLUDE	"exec/memory.i"
		INCLUDE	"exec/tasks.i"
		INCLUDE	"dos/dos.i"
		INCLUDE	"devices/timer.i"

		XDEF	_AtomicAnd
		XDEF	_AtomicOr
		XDEF	_MoveVBR
		XDEF	_Execute68k
		XDEF	_Execute68kTrap
		XDEF	_TrapHandlerAsm
		XDEF	_ExceptionHandlerAsm
		XDEF	_Scod060Patch1
		XDEF	_Scod060Patch2
		XDEF	_ThInitFPUPatch

		XREF	_OldTrapHandler
		XREF	_OldExceptionHandler
		XREF	_IllInstrHandler
		XREF	_PrivViolHandler
		XREF	_EmulatedSR
		XREF	_IRQSigMask
		XREF	_InterruptFlags
		XREF	_MainTask
		XREF	_SysBase
		XREF	_quit_emulator

		SECTION	text,CODE

*
* Atomic bit operations (don't trust the compiler)
*

_AtomicAnd	move.l	4(sp),a0
		move.l	8(sp),d0
		and.l	d0,(a0)
		rts

_AtomicOr	move.l	4(sp),a0
		move.l	8(sp),d0
		or.l	d0,(a0)
		rts

*
* Move VBR away from 0 if neccessary
*

_MoveVBR	movem.l	d0-d1/a0-a1/a5-a6,-(sp)
		move.l	_SysBase,a6

		lea	getvbr,a5		;VBR at 0?
		JSRLIB	Supervisor
		tst.l	d0
		bne.s	1$

		move.l	#$400,d0		;Yes, allocate memory for new table
		move.l	#MEMF_PUBLIC,d1
		JSRLIB	AllocMem
		tst.l	d0
		beq.s	1$

		JSRLIB	Disable

		move.l	d0,a5			;Copy old table
		move.l	d0,a1
		sub.l	a0,a0
		move.l	#$400,d0
		JSRLIB	CopyMem
		JSRLIB	CacheClearU

		move.l	a5,d0			;Set VBR
		lea	setvbr,a5
		JSRLIB	Supervisor

		JSRLIB	Enable

1$		movem.l	(sp)+,d0-d1/a0-a1/a5-a6
		rts

getvbr		movec	vbr,d0
		rte

setvbr		movec	d0,vbr
		rte

*
* Execute 68k subroutine (must be ended with rts)
* r->a[7] and r->sr are unused!
*

; void Execute68k(uint32 addr, M68kRegisters *r);
_Execute68k
		move.l	4(sp),d0		;Get arguments
		move.l	8(sp),a0

		movem.l	d2-d7/a2-a6,-(sp)	;Save registers

		move.l	a0,-(sp)		;Push pointer to M68kRegisters on stack
		pea	1$			;Push return address on stack
		move.l	d0,-(sp)		;Push pointer to 68k routine on stack
		movem.l	(a0),d0-d7/a0-a6	;Load registers from M68kRegisters

		rts				;Jump into 68k routine

1$		move.l	a6,-(sp)		;Save a6
		move.l	4(sp),a6		;Get pointer to M68kRegisters
		movem.l	d0-d7/a0-a5,(a6)	;Save d0-d7/a0-a5 to M68kRegisters
		move.l	(sp)+,56(a6)		;Save a6 to M68kRegisters
		addq.l	#4,sp			;Remove pointer from stack

		movem.l	(sp)+,d2-d7/a2-a6	;Restore registers
		rts

*
* Execute MacOS 68k trap
* r->a[7] and r->sr are unused!
*

; void Execute68kTrap(uint16 trap, M68kRegisters *r);
_Execute68kTrap
		move.l	4(sp),d0		;Get arguments
		move.l	8(sp),a0

		movem.l	d2-d7/a2-a6,-(sp)	;Save registers

		move.l	a0,-(sp)		;Push pointer to M68kRegisters on stack
		move.w	d0,-(sp)		;Push trap word on stack
		subq.l	#8,sp			;Create fake A-Line exception frame
		movem.l	(a0),d0-d7/a0-a6	;Load registers from M68kRegisters

		move.l	a2,-(sp)		;Save a2 and d2
		move.l	d2,-(sp)
		lea	1$,a2			;a2 points to return address
		move.w	16(sp),d2		;Load trap word into d2

		jmp	([$28.w],10)		;Jump into MacOS A-Line handler

1$		move.l	a6,-(sp)		;Save a6
		move.l	6(sp),a6		;Get pointer to M68kRegisters
		movem.l	d0-d7/a0-a5,(a6)	;Save d0-d7/a0-a5 to M68kRegisters
		move.l	(sp)+,56(a6)		;Save a6 to M68kRegisters
		addq.l	#6,sp			;Remove pointer and trap word from stack

		movem.l	(sp)+,d2-d7/a2-a6	;Restore registers
		rts

*
* Exception handler of main task (for 60Hz interrupts)
*

_ExceptionHandlerAsm
		move.l	d0,-(sp)		;Save d0

		and.l	#SIGBREAKF_CTRL_C,d0	;CTRL-C?
		bne.s	2$

		move.w	_EmulatedSR,d0		;Interrupts enabled in emulated SR?
		and.w	#$0700,d0
		bne	1$
		move.w	#$0064,-(sp)		;Yes, fake interrupt stack frame
		pea	1$
		move.w	_EmulatedSR,d0
		move.w	d0,-(sp)
		or.w	#$0100,d0		;Set interrupt level in SR
		move.w	d0,_EmulatedSR
		move.l	$64.w,a0		;Jump to MacOS interrupt handler
		jmp	(a0)

1$		move.l	(sp)+,d0		;Restore d0
		rts

2$		JSRLIB	Forbid			;Waiting for Dos signal?
		sub.l	a1,a1
		JSRLIB	FindTask
		move.l	d0,a0
		move.l	TC_SIGWAIT(a0),d0
		move.l	TC_SIGRECVD(a0),d1
		JSRLIB	Permit
		btst	#SIGB_DOS,d0
		beq	3$
		btst	#SIGB_DOS,d1
		bne	4$

3$		lea	TC_SIZE(a0),a0		;No, remove pending Dos packets
		JSRLIB	GetMsg

		move.w	_EmulatedSR,d0
		or.w	#$0700,d0		;Disable all interrupts
		move.w	d0,_EmulatedSR
		moveq	#0,d0			;Disable all exception signals
		moveq	#-1,d1
		JSRLIB	SetExcept
		jsr	_quit_emulator		;CTRL-C, quit emulator
4$		move.l	(sp)+,d0
		rts

*
* Process Manager 68060 FPU patches
*

_Scod060Patch1	fsave	-(sp)		;Save FPU state
		tst.b	2(sp)		;Null?
		beq.s	1$
		fmovem.x fp0-fp7,-(sp)	;No, save FPU registers
		fmove.l	fpiar,-(sp)
		fmove.l	fpsr,-(sp)
		fmove.l	fpcr,-(sp)
		pea	-1		;Push "FPU state saved" flag
1$		move.l	d1,-(sp)
		move.l	d0,-(sp)
		bsr.s	3$		;Switch integer registers and stack
		addq.l	#8,sp
		tst.b	2(sp)		;New FPU state null or "FPU state saved" flag set?
		beq.s	2$
		addq.l	#4,sp		;Flag set, skip it
		fmove.l	(sp)+,fpcr	;Restore FPU registers and state
		fmove.l	(sp)+,fpsr
		fmove.l	(sp)+,fpiar
		fmovem.x (sp)+,fp0-fp7
2$		frestore (sp)+
		movem.l	(sp)+,d0-d1
		rts

3$		move.l	4(sp),a0	;Switch integer registers and stack
		move	sr,-(sp)
		movem.l	d2-d7/a2-a6,-(sp)
		cmp.w	#0,a0
		beq.s	4$
		move.l	sp,(a0)
4$		move.l	$36(sp),a0
		movem.l	(a0)+,d2-d7/a2-a6
		move	(a0)+,sr
		move.l	a0,sp
		rts

_Scod060Patch2	move.l	d0,-(sp)	;Create 68060 null frame on stack
		move.l	d0,-(sp)
		move.l	d0,-(sp)
		frestore (sp)+		;and load it
		rts

*
* Thread Manager 68060 FPU patches
*

_ThInitFPUPatch	tst.b	$40(a4)
		bne.s	1$
		moveq	#0,d0		;Create 68060 null frame on stack
		move.l	d0,-(a3)
		move.l	d0,-(a3)
		move.l	d0,-(a3)
1$		rts

*
* Trap handler of main task
*

_TrapHandlerAsm	cmp.l	#4,(sp)			;Illegal instruction?
		beq.s	doillinstr
		cmp.l	#10,(sp)		;A-Line exception?
		beq.s	doaline
		cmp.l	#8,(sp)			;Privilege violation?
		beq.s	doprivviol

		move.l	_OldTrapHandler,-(sp)	;No, jump to old trap handler
		rts

*
* A-Line handler: call MacOS A-Line handler
*

doaline		move.l	a0,(sp)			;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.l	8(sp),-(a0)		;Copy stack frame to user stack
		move.l	4(sp),-(a0)
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0

		addq.l	#8,sp			;Remove exception frame from supervisor stack
		andi	#$d8ff,sr		;Switch to user mode, enable interrupts

		move.l	$28.w,-(sp)		;Jump to MacOS exception handler
		rts

*
* Illegal instruction handler: call IllInstrHandler() (which calls EmulOp())
*   to execute extended opcodes (see emul_op.h)
*

doillinstr	move.l	a6,(sp)			;Save a6
		move.l	usp,a6			;Get user stack pointer

		move.l	a6,-10(a6)		;Push USP (a7)
		move.l	6(sp),-(a6)		;Push PC
		move.w	4(sp),-(a6)		;Push SR
		subq.l	#4,a6			;Skip saved USP
		move.l	(sp),-(a6)		;Push old a6
		movem.l	d0-d7/a0-a5,-(a6)	;Push remaining registers
		move.l	a6,usp			;Update USP

		add.w	#12,sp			;Remove exception frame from supervisor stack
		andi	#$d8ff,sr		;Switch to user mode, enable interrupts

		move.l	a6,-(sp)		;Jump to IllInstrHandler() in main.cpp
		jsr	_IllInstrHandler
		addq.l	#4,sp

		movem.l	(sp)+,d0-d7/a0-a6	;Restore registers
		addq.l	#4,sp			;Skip saved USP (!!)
		rtr				;Return from exception

*
* Privilege violation handler: MacOS runs in supervisor mode,
*   so we have to emulate certain privileged instructions
*

doprivviol	move.l	d0,(sp)			;Save d0
		move.w	([6,sp]),d0		;Get instruction word

		cmp.w	#$40e7,d0		;move sr,-(sp)?
		beq	pushsr
		cmp.w	#$46df,d0		;move (sp)+,sr?
		beq	popsr

		cmp.w	#$007c,d0		;ori #xxxx,sr?
		beq	orisr
		cmp.w	#$027c,d0		;andi #xxxx,sr?
		beq	andisr

		cmp.w	#$46fc,d0		;move #xxxx,sr?
		beq	movetosrimm

		cmp.w	#$46ef,d0		;move (xxxx,sp),sr?
		beq	movetosrsprel
		cmp.w	#$46d8,d0		;move (a0)+,sr?
		beq	movetosra0p
		cmp.w	#$46d9,d0		;move (a1)+,sr?
		beq	movetosra1p

		cmp.w	#$40f8,d0		;move sr,xxxx.w?
		beq	movefromsrabs
		cmp.w	#$40d0,d0		;move sr,(a0)?
		beq	movefromsra0
		cmp.w	#$40d7,d0		;move sr,(sp)?
		beq	movefromsra0

		cmp.w	#$f327,d0		;fsave -(sp)?
		beq	fsavepush
		cmp.w	#$f35f,d0		;frestore (sp)+?
		beq	frestorepop

		cmp.w	#$4e73,d0		;rte?
		beq	pvrte

		cmp.w	#$40c0,d0		;move sr,d0?
		beq	movefromsrd0
		cmp.w	#$40c1,d0		;move sr,d1?
		beq	movefromsrd1
		cmp.w	#$40c2,d0		;move sr,d2?
		beq	movefromsrd2
		cmp.w	#$40c3,d0		;move sr,d3?
		beq	movefromsrd3
		cmp.w	#$40c4,d0		;move sr,d4?
		beq	movefromsrd4
		cmp.w	#$40c5,d0		;move sr,d5?
		beq	movefromsrd5
		cmp.w	#$40c6,d0		;move sr,d6?
		beq	movefromsrd6
		cmp.w	#$40c7,d0		;move sr,d7?
		beq	movefromsrd7

		cmp.w	#$46c0,d0		;move d0,sr?
		beq	movetosrd0
		cmp.w	#$46c1,d0		;move d1,sr?
		beq	movetosrd1
		cmp.w	#$46c2,d0		;move d2,sr?
		beq	movetosrd2
		cmp.w	#$46c3,d0		;move d3,sr?
		beq	movetosrd3
		cmp.w	#$46c4,d0		;move d4,sr?
		beq	movetosrd4
		cmp.w	#$46c5,d0		;move d5,sr?
		beq	movetosrd5
		cmp.w	#$46c6,d0		;move d6,sr?
		beq	movetosrd6
		cmp.w	#$46c7,d0		;move d7,sr?
		beq	movetosrd7

		cmp.w	#$4e7a,d0		;movec cr,x?
		beq	movecfromcr
		cmp.w	#$4e7b,d0		;movec x,cr?
		beq	movectocr

		cmp.w	#$f478,d0		;cpusha dc?
		beq	cpushadc
		cmp.w	#$f4f8,d0		;cpusha dc/ic?
		beq	cpushadcic

pv_unhandled	move.l	(sp),d0			;Unhandled instruction, jump to handler in main.cpp
		move.l	a6,(sp)			;Save a6
		move.l	usp,a6			;Get user stack pointer

		move.l	a6,-10(a6)		;Push USP (a7)
		move.l	6(sp),-(a6)		;Push PC
		move.w	4(sp),-(a6)		;Push SR
		subq.l	#4,a6			;Skip saved USP
		move.l	(sp),-(a6)		;Push old a6
		movem.l	d0-d7/a0-a5,-(a6)	;Push remaining registers
		move.l	a6,usp			;Update USP

		add.w	#12,sp			;Remove exception frame from supervisor stack
		andi	#$d8ff,sr		;Switch to user mode, enable interrupts

		move.l	a6,-(sp)		;Jump to PrivViolHandler() in main.cpp
		jsr	_PrivViolHandler
		addq.l	#4,sp

		movem.l	(sp)+,d0-d7/a0-a6	;Restore registers
		addq.l	#4,sp			;Skip saved USP
		rtr				;Return from exception

; move sr,-(sp)
pushsr		move.l	a0,-(sp)		;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.w	8(sp),d0		;Get CCR from exception stack frame
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		move.w	d0,-(a0)		;Store SR on user stack
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0
		move.l	(sp)+,d0		;Restore d0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; move (sp)+,sr
popsr		move.l	a0,-(sp)		;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.w	(a0)+,d0		;Get SR from user stack
		move.w	d0,8(sp)		;Store into CCR on exception stack frame
		and.w	#$00ff,8(sp)
		and.w	#$2700,d0		;Extract supervisor bits
		move.w	d0,_EmulatedSR		;And save them

		and.w	#$0700,d0		;Rethrow exception if interrupts are pending and reenabled
		bne	1$
		tst.l	_InterruptFlags
		beq	1$
		movem.l	d0-d1/a0-a1/a6,-(sp)
		move.l	_SysBase,a6
		move.l	_MainTask,a1
		move.l	_IRQSigMask,d0
		JSRLIB	Signal
		movem.l	(sp)+,d0-d1/a0-a1/a6
1$
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0
		move.l	(sp)+,d0		;Restore d0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; ori #xxxx,sr
orisr		move.w	4(sp),d0		;Get CCR from stack
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		or.w	([6,sp],2),d0		;Or with immediate value
		move.w	d0,4(sp)		;Store into CCR on stack
		and.w	#$00ff,4(sp)
		and.w	#$2700,d0		;Extract supervisor bits
		move.w	d0,_EmulatedSR		;And save them
		move.l	(sp)+,d0		;Restore d0
		addq.l	#4,2(sp)		;Skip instruction
		rte

; andi #xxxx,sr
andisr		move.w	4(sp),d0		;Get CCR from stack
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		and.w	([6,sp],2),d0		;And with immediate value
storesr4	move.w	d0,4(sp)		;Store into CCR on stack
		and.w	#$00ff,4(sp)
		and.w	#$2700,d0		;Extract supervisor bits
		move.w	d0,_EmulatedSR		;And save them

		and.w	#$0700,d0		;Rethrow exception if interrupts are pending and reenabled
		bne.s	1$
		tst.l	_InterruptFlags
		beq.s	1$
		movem.l	d0-d1/a0-a1/a6,-(sp)
		move.l	_SysBase,a6
		move.l	_MainTask,a1
		move.l	_IRQSigMask,d0
		JSRLIB	Signal
		movem.l	(sp)+,d0-d1/a0-a1/a6
1$		move.l	(sp)+,d0		;Restore d0
		addq.l	#4,2(sp)		;Skip instruction
		rte

; move #xxxx,sr
movetosrimm	move.w	([6,sp],2),d0		;Get immediate value
		bra.s	storesr4

; move (xxxx,sp),sr
movetosrsprel	move.l	a0,-(sp)		;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.w	([10,sp],2),d0		;Get offset
		move.w	(a0,d0.w),d0		;Read word
		move.l	(sp)+,a0		;Restore a0
		bra.s	storesr4

; move (a0)+,sr
movetosra0p	move.w	(a0)+,d0		;Read word
		bra	storesr2

; move (a1)+,sr
movetosra1p	move.w	(a1)+,d0		;Read word
		bra	storesr2

; move sr,xxxx.w
movefromsrabs	move.l	a0,-(sp)		;Save a0
		move.w	([10,sp],2),a0		;Get address
		move.w	8(sp),d0		;Get CCR
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		move.w	d0,(a0)			;Store SR
		move.l	(sp)+,a0		;Restore a0
		move.l	(sp)+,d0		;Restore d0
		addq.l	#4,2(sp)		;Skip instruction
		rte

; move sr,(a0)
movefromsra0	move.w	4(sp),d0		;Get CCR
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		move.w	d0,(a0)			;Store SR
		move.l	(sp)+,d0		;Restore d0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; move sr,(sp)
movefromsrsp	move.l	a0,-(sp)		;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.w	8(sp),d0		;Get CCR
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		move.w	d0,(a0)			;Store SR
		move.l	(sp)+,a0		;Restore a0
		move.l	(sp)+,d0		;Restore d0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; fsave -(sp)
fsavepush	move.l	(sp),d0			;Restore d0
		move.l	a0,(sp)			;Save a0
		move.l	usp,a0			;Get user stack pointer
		fsave	-(a0)			;Push FP state
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; frestore (sp)+
frestorepop	move.l	(sp),d0			;Restore d0
		move.l	a0,(sp)			;Save a0
		move.l	usp,a0			;Get user stack pointer
		frestore (a0)+			;Restore FP state
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0
		addq.l	#2,2(sp)		;Skip instruction
		rte

; rte (only handles format 0)
pvrte		move.l	a0,-(sp)		;Save a0
		move.l	usp,a0			;Get user stack pointer
		move.w	(a0)+,d0		;Get SR from user stack
		move.w	d0,8(sp)		;Store into CCR on exception stack frame
		and.w	#$00ff,8(sp)
		and.w	#$2700,d0		;Extract supervisor bits
		move.w	d0,_EmulatedSR		;And save them
		move.l	(a0)+,10(sp)		;Store return address in exception stack frame
		addq.l	#2,a0			;Skip format word
		move.l	a0,usp			;Update USP
		move.l	(sp)+,a0		;Restore a0
		move.l	(sp)+,d0		;Restore d0
		rte

; move sr,dx
movefromsrd0	addq.l	#4,sp			;Skip saved d0
		moveq	#0,d0
		move.w	(sp),d0			;Get CCR
		or.w	_EmulatedSR,d0		;Add emulated supervisor bits
		addq.l	#2,2(sp)		;Skip instruction
		rte

movefromsrd1	move.l	(sp)+,d0
		moveq	#0,d1
		move.w	(sp),d1
		or.w	_EmulatedSR,d1
		addq.l	#2,2(sp)
		rte

movefromsrd2	move.l	(sp)+,d0
		moveq	#0,d2
		move.w	(sp),d2
		or.w	_EmulatedSR,d2
		addq.l	#2,2(sp)
		rte

movefromsrd3	move.l	(sp)+,d0
		moveq	#0,d3
		move.w	(sp),d3
		or.w	_EmulatedSR,d3
		addq.l	#2,2(sp)
		rte

movefromsrd4	move.l	(sp)+,d0
		moveq	#0,d4
		move.w	(sp),d4
		or.w	_EmulatedSR,d4
		addq.l	#2,2(sp)
		rte

movefromsrd5	move.l	(sp)+,d0
		moveq	#0,d5
		move.w	(sp),d5
		or.w	_EmulatedSR,d5
		addq.l	#2,2(sp)
		rte

movefromsrd6	move.l	(sp)+,d0
		moveq	#0,d6
		move.w	(sp),d6
		or.w	_EmulatedSR,d6
		addq.l	#2,2(sp)
		rte

movefromsrd7	move.l	(sp)+,d0
		moveq	#0,d7
		move.w	(sp),d7
		or.w	_EmulatedSR,d7
		addq.l	#2,2(sp)
		rte

; move dx,sr
movetosrd0	move.l	(sp),d0
storesr2	move.w	d0,4(sp)
		and.w	#$00ff,4(sp)
		and.w	#$2700,d0
		move.w	d0,_EmulatedSR

		and.w	#$0700,d0		;Rethrow exception if interrupts are pending and reenabled
		bne.s	1$
		tst.l	_InterruptFlags
		beq.s	1$
		movem.l	d0-d1/a0-a1/a6,-(sp)
		move.l	_SysBase,a6
		move.l	_MainTask,a1
		move.l	_IRQSigMask,d0
		JSRLIB	Signal
		movem.l	(sp)+,d0-d1/a0-a1/a6
1$		move.l	(sp)+,d0
		addq.l	#2,2(sp)
		rte

movetosrd1	move.l	d1,d0
		bra.s	storesr2

movetosrd2	move.l	d2,d0
		bra.s	storesr2

movetosrd3	move.l	d3,d0
		bra.s	storesr2

movetosrd4	move.l	d4,d0
		bra.s	storesr2

movetosrd5	move.l	d5,d0
		bra.s	storesr2

movetosrd6	move.l	d6,d0
		bra.s	storesr2

movetosrd7	move.l	d7,d0
		bra.s	storesr2

; movec cr,x
movecfromcr	move.w	([6,sp],2),d0		;Get next instruction word

		cmp.w	#$8801,d0		;movec vbr,a0?
		beq.s	movecvbra0
		cmp.w	#$9801,d0		;movec vbr,a1?
		beq.s	movecvbra1
		cmp.w	#$0002,d0		;movec cacr,d0?
		beq.s	moveccacrd0
		cmp.w	#$1002,d0		;movec cacr,d1?
		beq.s	moveccacrd1
		cmp.w	#$0003,d0		;movec tc,d0?
		beq.s	movectcd0
		cmp.w	#$1003,d0		;movec tc,d1?
		beq.s	movectcd1

		bra	pv_unhandled

; movec cacr,d0
moveccacrd0	move.l	(sp)+,d0
		move.l	#$3111,d0		;All caches and bursts on
		addq.l	#4,2(sp)
		rte

; movec cacr,d1
moveccacrd1	move.l	(sp)+,d0
		move.l	#$3111,d1		;All caches and bursts on
		addq.l	#4,2(sp)
		rte

; movec vbr,a0
movecvbra0	move.l	(sp)+,d0
		sub.l	a0,a0			;VBR always appears to be at 0
		addq.l	#4,2(sp)
		rte

; movec vbr,a1
movecvbra1	move.l	(sp)+,d0
		sub.l	a1,a1			;VBR always appears to be at 0
		addq.l	#4,2(sp)
		rte

; movec tc,d0
movectcd0	addq.l	#4,sp
		moveq	#0,d0			;MMU is always off
		addq.l	#4,2(sp)
		rte

; movec tc,d1
movectcd1	addq.l	#4,sp
		moveq	#0,d1			;MMU is always off
		addq.l	#4,2(sp)
		rte

; movec x,cr
movectocr	move.w	([6,sp],2),d0		;Get next instruction word

		cmp.w	#$0801,d0		;movec d0,vbr?
		beq.s	movectovbr
		cmp.w	#$0002,d0		;movec d0,cacr?
		beq.s	movectocacr
		cmp.w	#$1002,d0		;movec d1,cacr?
		beq.s	movectocacr

		bra	pv_unhandled

; movec x,vbr
movectovbr	move.l	(sp)+,d0		;Ignore moves to VBR
		addq.l	#4,2(sp)
		rte

; movec dx,cacr
movectocacr	movem.l	d1/a0-a1/a6,-(sp)	;Move to CACR, clear caches
		move.l	_SysBase,a6
		JSRLIB	CacheClearU
		movem.l	(sp)+,d1/a0-a1/a6
		move.l	(sp)+,d0
		addq.l	#4,2(sp)
		rte

; cpusha
cpushadc
cpushadcic	movem.l	d1/a0-a1/a6,-(sp)	;Clear caches
		move.l	_SysBase,a6
		JSRLIB	CacheClearU
		movem.l	(sp)+,d1/a0-a1/a6
		move.l	(sp)+,d0
		addq.l	#2,2(sp)
		rte

		END
