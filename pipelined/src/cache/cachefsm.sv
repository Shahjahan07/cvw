///////////////////////////////////////////
// dcache (data cache) fsm
//
// Written: ross1728@gmail.com August 25, 2021
//          Implements the L1 data cache fsm
//
// Purpose: Controller for the dcache fsm
//
// A component of the Wally configurable RISC-V project.
//
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

`include "wally-config.vh"

module cachefsm
  (input logic clk,
   input logic 		  reset,
   // inputs from IEU
   input logic [1:0]  RW,
   input logic [1:0]  Atomic,
   input logic 		  FlushCache,
   // hazard inputs
   input logic 		  CPUBusy,
   input logic 		  CacheableM,
   // interlock fsm
   input logic 		  IgnoreRequest,
   // Bus inputs
   input logic 		  CacheBusAck,
   // dcache internals
   input logic 		  CacheHit,
   input logic 		  VictimDirty,
   input logic 		  FlushAdrFlag,
  
   // hazard outputs
   output logic 	  CacheStall,
   // counter outputs
   output logic 	  CacheMiss,
   output logic 	  CacheAccess,
   // Bus outputs
   output logic 	  CacheCommitted,
   output logic 	  CacheWriteLine,
   output logic 	  CacheFetchLine,

   // dcache internals
   output logic [1:0] SelAdr,
   output logic 	  SetValid,
   output logic 	  ClearValid,
   output logic 	  SetDirty,
   output logic 	  ClearDirty,
   output logic 	  SRAMWordWriteEnableM,
   output logic 	  SRAMLineWriteEnableM,
   output logic 	  SelEvict,
   output logic 	  LRUWriteEn,
   output logic 	  SelFlush,
   output logic 	  SelLastFlushAdr,
   output logic 	  FlushAdrCntEn,
   output logic 	  FlushWayCntEn, 
   output logic 	  FlushAdrCntRst,
   output logic 	  FlushWayCntRst,
   output logic 	  VDWriteEnable

   );
  
  logic 			  AnyCPUReqM;
  
  typedef enum 		  {STATE_READY,

					   STATE_MISS_FETCH_WDV,
					   STATE_MISS_FETCH_DONE,
					   STATE_MISS_EVICT_DIRTY,
					   STATE_MISS_WRITE_CACHE_LINE,
					   STATE_MISS_READ_WORD,
					   STATE_MISS_READ_WORD_DELAY,
					   STATE_MISS_WRITE_WORD,

					   STATE_CPU_BUSY,
					   STATE_CPU_BUSY_FINISH_AMO,
  
					   STATE_FLUSH,
					   STATE_FLUSH_WRITE_BACK,
					   STATE_FLUSH_CLEAR_DIRTY} statetype;

  (* mark_debug = "true" *) statetype CurrState, NextState;

  assign AnyCPUReqM = |RW | (|Atomic);

  // outputs for the performance counters.
  assign CacheAccess = AnyCPUReqM & CacheableM & CurrState == STATE_READY;
  assign CacheMiss = CacheAccess & CacheableM & ~CacheHit;

  always_ff @(posedge clk)
    if (reset)    CurrState <= #1 STATE_READY;
    else CurrState <= #1 NextState;  
  
  // next state logic and some state ouputs.
  always_comb begin
    CacheStall = 1'b0;
    SelAdr = 2'b00;
    SetValid = 1'b0;
    ClearValid = 1'b0;
    SetDirty = 1'b0;    
    ClearDirty = 1'b0;
    SRAMWordWriteEnableM = 1'b0;
    SRAMLineWriteEnableM = 1'b0;
    SelEvict = 1'b0;
    LRUWriteEn = 1'b0;
    SelFlush = 1'b0;
    FlushAdrCntEn = 1'b0;
    FlushWayCntEn = 1'b0;
    FlushAdrCntRst = 1'b0;
    FlushWayCntRst = 1'b0;	
    VDWriteEnable = 1'b0;
    NextState = STATE_READY;
	CacheFetchLine = 1'b0;
	CacheWriteLine = 1'b0;
	SelLastFlushAdr = 1'b0;

    case (CurrState)
      STATE_READY: begin

		CacheStall = 1'b0;
		SelAdr = 2'b00;
		SRAMWordWriteEnableM = 1'b0;
		SetDirty = 1'b0;
		LRUWriteEn = 1'b0;

		// TLB Miss	
		if(IgnoreRequest) begin
		  // the LSU arbiter has not yet selected the PTW.
		  // The CPU needs to be stalled until that happens.
		  // If we set CacheStall for 1 cycle before going to
		  // PTW ready the CPU will stall.
		  // The page table walker asserts it's control 1 cycle
		  // after the TLBs miss.
		  SelAdr = 2'b01;
		  NextState = STATE_READY;
		end

		// Flush dcache to next level of memory
		else if(FlushCache) begin
		  NextState = STATE_FLUSH;
		  CacheStall = 1'b1;
		  SelAdr = 2'b10;
		  FlushAdrCntRst = 1'b1;
		  FlushWayCntRst = 1'b1;	
		end
		
		// amo hit
		else if(Atomic[1] & (&RW) & CacheableM & CacheHit) begin
		  SelAdr = 2'b01;
		  CacheStall = 1'b0;
		  
		  if(CPUBusy) begin 
			NextState = STATE_CPU_BUSY_FINISH_AMO;
			SelAdr = 2'b01;
		  end
		  else begin
			SRAMWordWriteEnableM = 1'b1;
			SetDirty = 1'b1;
			LRUWriteEn = 1'b1;
			NextState = STATE_READY;
		  end
		end
		// read hit valid cached
		else if(RW[1] & CacheableM & CacheHit) begin
		  CacheStall = 1'b0;
		  LRUWriteEn = 1'b1;
		  
		  if(CPUBusy) begin
			NextState = STATE_CPU_BUSY;
            SelAdr = 2'b01;
		  end
		  else begin
			NextState = STATE_READY;
	      end
		end
		// write hit valid cached
		else if (RW[0] & CacheableM & CacheHit) begin
		  SelAdr = 2'b01;
		  CacheStall = 1'b0;
		  SRAMWordWriteEnableM = 1'b1;
		  SetDirty = 1'b1;
		  LRUWriteEn = 1'b1;
		  
		  if(CPUBusy) begin 
			NextState = STATE_CPU_BUSY;
			SelAdr = 2'b01;
		  end
		  else begin
			NextState = STATE_READY;
		  end
		end
		// read or write miss valid cached
		else if((|RW) & CacheableM & ~CacheHit) begin
		  NextState = STATE_MISS_FETCH_WDV;
		  CacheStall = 1'b1;
		  CacheFetchLine = 1'b1;
		end
		else NextState = STATE_READY;
      end
      
      STATE_MISS_FETCH_WDV: begin
		CacheStall = 1'b1;
		SelAdr = 2'b01;
		
		if (CacheBusAck) begin
          NextState = STATE_MISS_FETCH_DONE;
        end else begin
          NextState = STATE_MISS_FETCH_WDV;
        end
      end

      STATE_MISS_FETCH_DONE: begin
		CacheStall = 1'b1;
		SelAdr = 2'b01;
		if(VictimDirty) begin
		  NextState = STATE_MISS_EVICT_DIRTY;
		  CacheWriteLine = 1'b1;
		end else begin
		  NextState = STATE_MISS_WRITE_CACHE_LINE;
		end
      end

      STATE_MISS_WRITE_CACHE_LINE: begin
		SRAMLineWriteEnableM = 1'b1;
		CacheStall = 1'b1;
		NextState = STATE_MISS_READ_WORD;
		SelAdr = 2'b01;
		SetValid = 1'b1;
		ClearDirty = 1'b1;
		//LRUWriteEn = 1'b1;  // DO not update LRU on SRAM fetch update.  Wait for subsequent read/write
      end

      STATE_MISS_READ_WORD: begin
		SelAdr = 2'b01;
		CacheStall = 1'b1;
		if (RW[0] & ~Atomic[1]) begin // handles stores and amo write.
		  NextState = STATE_MISS_WRITE_WORD;
		end else begin
		  NextState = STATE_MISS_READ_WORD_DELAY;
		  // delay state is required as the read signal RW[1] is still high when we
		  // return to the ready state because the cache is stalling the cpu.
		end
      end

      STATE_MISS_READ_WORD_DELAY: begin
		//SelAdr = 2'b01;
		SRAMWordWriteEnableM = 1'b0;
		SetDirty = 1'b0;
		LRUWriteEn = 1'b0;
		if(&RW & Atomic[1]) begin // amo write
		  SelAdr = 2'b01;
		  if(CPUBusy) begin 
			NextState = STATE_CPU_BUSY_FINISH_AMO;
		  end
		  else begin
			SRAMWordWriteEnableM = 1'b1;
			SetDirty = 1'b1;
			LRUWriteEn = 1'b1;
			NextState = STATE_READY;
		  end
		end else begin
		  LRUWriteEn = 1'b1;
		  if(CPUBusy) begin 
			NextState = STATE_CPU_BUSY;
			SelAdr = 2'b01;
		  end
		  else begin
			NextState = STATE_READY;
		  end
		end
      end

      STATE_MISS_WRITE_WORD: begin
		SRAMWordWriteEnableM = 1'b1;
		SetDirty = 1'b1;
		SelAdr = 2'b01;
		LRUWriteEn = 1'b1;
		if(CPUBusy) begin 
		  NextState = STATE_CPU_BUSY;
		  SelAdr = 2'b01;
		end
		else begin
		  NextState = STATE_READY;
		end
      end

      STATE_MISS_EVICT_DIRTY: begin
		CacheStall = 1'b1;
		SelAdr = 2'b01;
		SelEvict = 1'b1;
		if(CacheBusAck) begin
		  NextState = STATE_MISS_WRITE_CACHE_LINE;
		end else begin
		  NextState = STATE_MISS_EVICT_DIRTY;
		end	  
      end


      STATE_CPU_BUSY: begin
		SelAdr = 2'b00;
		if(CPUBusy) begin
		  NextState = STATE_CPU_BUSY;
		  SelAdr = 2'b01;
		end
		else begin
		  NextState = STATE_READY;
		end
      end

      STATE_CPU_BUSY_FINISH_AMO: begin
		SelAdr = 2'b01;
		SRAMWordWriteEnableM = 1'b0;
		SetDirty = 1'b0;
		LRUWriteEn = 1'b0;
		if(CPUBusy) begin
		  NextState = STATE_CPU_BUSY_FINISH_AMO;
		end
		else begin
		  SRAMWordWriteEnableM = 1'b1;
		  SetDirty = 1'b1;
		  LRUWriteEn = 1'b1;
		  NextState = STATE_READY;
		end
      end

      STATE_FLUSH: begin
		CacheStall = 1'b1;
		SelAdr = 2'b10;
		SelFlush = 1'b1;
		FlushAdrCntEn = 1'b1;
		FlushWayCntEn = 1'b1;
		SelLastFlushAdr = 1'b0;
		if(VictimDirty) begin
		  NextState = STATE_FLUSH_WRITE_BACK;
		  FlushAdrCntEn = 1'b0;
		  FlushWayCntEn = 1'b0;
		  CacheWriteLine = 1'b1;
		  SelLastFlushAdr = 1'b1;
		end else if (FlushAdrFlag) begin
		  NextState = STATE_READY;
		  CacheStall = 1'b0;
		  FlushAdrCntEn = 1'b0;
		  FlushWayCntEn = 1'b0;	
		end else begin
		  NextState = STATE_FLUSH;
		end
      end

      STATE_FLUSH_WRITE_BACK: begin
		CacheStall = 1'b1;
		SelAdr = 2'b10;
		SelFlush = 1'b1;
		SelLastFlushAdr = 1'b1;
		if(CacheBusAck) begin
		  NextState = STATE_FLUSH_CLEAR_DIRTY;
		end else begin
		  NextState = STATE_FLUSH_WRITE_BACK;
		end	  
      end

      STATE_FLUSH_CLEAR_DIRTY: begin
		CacheStall = 1'b1;
		ClearDirty = 1'b1;
		VDWriteEnable = 1'b1;
		SelFlush = 1'b1;
		SelAdr = 2'b10;
		FlushAdrCntEn = 1'b0;
		FlushWayCntEn = 1'b0;
		SelLastFlushAdr = 1'b0;
		if(FlushAdrFlag) begin
		  NextState = STATE_READY;
		  CacheStall = 1'b0;
		  SelAdr = 2'b00;
		end else begin
		  NextState = STATE_FLUSH;
		  FlushAdrCntEn = 1'b1;
		  FlushWayCntEn = 1'b1;	
		end
      end

      default: begin
		NextState = STATE_READY;
      end
    endcase
  end

  assign CacheCommitted = CurrState != STATE_READY;

endmodule // cachefsm
