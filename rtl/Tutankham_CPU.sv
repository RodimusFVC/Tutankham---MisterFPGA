//============================================================================
//
//  Tutankham main PCB model (based on Time Pilot core)
//  Copyright (C) 2021 Ace, Artemio Urbina & RTLEngineering
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

//Module declaration, I/O ports
module Tutankham_CPU
(
	input         reset,
	input         clk_49m,          //Actual frequency: 49.152MHz
	output  [4:0] red, green, blue, //15-bit RGB, 5 bits per color
	output        video_hsync, video_vsync, video_csync, //CSync not needed for MISTer
	output        video_hblank, video_vblank,
	output        ce_pix,

	input   [7:0] controls_dip,
	input  [15:0] dip_sw,
	output  [7:0] cpubrd_Dout,
	output        cpubrd_A5, cpubrd_A6,
	output        cs_sounddata, irq_trigger,
	output        cs_dip2, cs_controls_dip1,

	//Screen centering (alters HSync, VSync and VBlank timing in the Konami 082 to reposition the video output)
	input   [3:0] h_center, v_center,

	//ROM chip selects for main program ROMs (6x 4KB)
	input         rom_m1_cs_i, rom_m2_cs_i, rom_m3_cs_i,
	input         rom_m4_cs_i, rom_m5_cs_i, rom_m6_cs_i,
	//ROM chip selects for banked graphics ROMs (9x 4KB)
	input         bank0_cs_i, bank1_cs_i, bank2_cs_i,
	input         bank3_cs_i, bank4_cs_i, bank5_cs_i,
	input         bank6_cs_i, bank7_cs_i, bank8_cs_i,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_data,
	input         ioctl_wr,

	input         pause,

	input  [15:0] hs_address,
	input   [7:0] hs_data_in,
	output  [7:0] hs_data_out,
	input         hs_write
);

//------------------------------------------------------- Signal outputs -------------------------------------------------------//

//Assign active high HBlank and VBlank outputs
assign video_hblank = hblk;
assign video_vblank = vblk;

//Output pixel clock enable
assign ce_pix = cen_6m;

//Output select lines for player inputs and DIP switches to sound board
assign cs_controls_dip1 = cs_dsw1;
assign cs_dip2 = cs_dsw2;

//Output primary MC6809E address lines A5 and A6 to sound board
assign cpubrd_A5 = z80_A[5];
assign cpubrd_A6 = z80_A[6];

//Assign CPU board data output to sound board
assign cpubrd_Dout = z80_Dout;

//Generate and output chip select for sound command
assign cs_sounddata = cs_soundcmd;

//Generate sound IRQ trigger
reg sound_irq = 1;
always_ff @(posedge clk_49m) begin
	if(cen_3m) begin
		if(cs_soundirq)
			sound_irq <= 1;
		else
			sound_irq <= 0;
	end
end
assign irq_trigger = sound_irq;

//------------------------------------------------------- Clock division -------------------------------------------------------//

//Generate 6.144MHz and 3.072MHz clock enables
reg [3:0] div = 4'd0;
always_ff @(posedge clk_49m) begin
	div <= div + 4'd1;
end
wire cen_6m = !div[2:0];
wire cen_3m = !div;

//MC6809E E and Q clock generation from existing div[3:0] counter
//div rolls over every 16 clocks: E toggles at 49.152MHz/16 = 3.072MHz, E freq = 1.536MHz
//Q leads E by 90 degrees (4 system clocks)

//MC6809E E and Q clock generation
//The 6809E on Tutankham runs at 1.536MHz (E/Q are 90-degree shifted phases).
//From 49.152MHz input, one full E/Q cycle is 32 master clocks.
reg [4:0] cpu_div = 5'd0;									// Fixes
reg cpu_E = 0;
reg cpu_Q = 0;
always_ff @(posedge clk_49m) begin
	if(~pause) begin
//		case(div[3:0])
//			4'd0:  begin cpu_E <= 1; cpu_Q <= 0; end
//			4'd4:  begin cpu_E <= 1; cpu_Q <= 1; end
//			4'd8:  begin cpu_E <= 0; cpu_Q <= 1; end
//			4'd12: begin cpu_E <= 0; cpu_Q <= 0; end
		cpu_div <= cpu_div + 5'd1;							// Fixes
		case(cpu_div)										// Fixes
			5'd0:  begin cpu_E <= 1; cpu_Q <= 0; end		// Fixes
			5'd8:  begin cpu_E <= 1; cpu_Q <= 1; end		// Fixes
			5'd16: begin cpu_E <= 0; cpu_Q <= 1; end		// Fixes
			5'd24: begin cpu_E <= 0; cpu_Q <= 0; end		// Fixes
			default: ;
		endcase
	end
end

//------------------------------------------------------------ CPUs ------------------------------------------------------------//

//Primary CPU - Motorola MC6809E
wire [15:0] z80_A;
wire [7:0] z80_Dout;
wire cpu_RnW;
mc6809e E3
(
	.D(z80_Din),
	.DOut(z80_Dout),
	.ADDR(z80_A),
	.RnW(cpu_RnW),
	.E(cpu_E),
	.Q(cpu_Q),
	.nIRQ(1'b1),
	.nFIRQ(1'b1),
	.nNMI(n_nmi),
	.BS(),
	.BA(),
	.AVMA(),
	.BUSY(),
	.LIC(),
	.nHALT(1'b1),
	.nRESET(~reset)							// Fixes
);

//------------------------------------------------------ Address decoding ------------------------------------------------------//

//Tutankham memory map
wire n_cs_videoram = ~(z80_A[15] == 1'b0);               // 0x0000-0x7FFF (32KB video RAM)
wire n_cs_workram  = ~(z80_A[15:11] == 5'b10000);         // 0x8000-0x87FF (2KB work RAM)
wire n_cs_workram2 = ~(z80_A[15:11] == 5'b10001);         // 0x8800-0x8FFF (2KB work RAM expansion)
wire n_cs_bankrom  = ~(z80_A[15:12] == 4'b1001);          // 0x9000-0x9FFF (4KB banked ROM window)
wire n_cs_mainrom  = ~(z80_A[15:13] == 3'b101 |
                       z80_A[15:13] == 3'b110 |
                       z80_A[15:13] == 3'b111);            // 0xA000-0xFFFF (24KB main ROM)

//Tutankham I/O decoding (memory-mapped in 0x8000-0x87FF region)
wire cs_palette    = (z80_A[15:4] == 12'h800);             // 0x8000-0x800F (palette RAM)
wire cs_scroll     = (z80_A[15:4] == 12'h810);             // 0x8100-0x810F (scroll register)
wire cs_watchdog   = (z80_A[15:4] == 12'h812);             // 0x8120 (watchdog)
wire cs_dsw2       = (z80_A[15:4] == 12'h816);             // 0x8160 (DIP SW2)
wire cs_in0        = (z80_A[15:4] == 12'h818);             // 0x8180 (IN0: coins, start)
wire cs_in1        = (z80_A[15:4] == 12'h81A);             // 0x81A0 (IN1: P1 controls)
wire cs_in2        = (z80_A[15:4] == 12'h81C);             // 0x81C0 (IN2: P2 controls)
wire cs_dsw1       = (z80_A[15:4] == 12'h81E);             // 0x81E0 (DIP SW1)
wire cs_mainlatch  = (z80_A[15:3] == 13'h1040) & ~cpu_RnW; // 0x8200-0x8207 (main latch)
wire cs_banksel_wr = (z80_A[15:8] == 8'h83) & ~cpu_RnW;    // 0x8300 (bank select)
wire cs_soundon    = (z80_A[15:8] == 8'h86) & ~cpu_RnW;    // 0x8600 (sound enable)
wire cs_soundcmd   = (z80_A[15:8] == 8'h87) & ~cpu_RnW;    // 0x8700 (sound command)

//ROM bank select register (0x8300)
reg [3:0] rom_bank = 4'd0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		rom_bank <= 4'd0;
	else if(cen_3m && cs_banksel_wr)
		rom_bank <= z80_Dout[3:0];
end

//------------------------------------------------------ CPU data input mux ---------------------------------------------------//

// Input data from controls (placeholder - proper wiring in Phase 5)
wire [7:0] dsw1_data = ~dip_sw[7:0];   // DIP switch 1 (active low)
wire [7:0] dsw2_data = ~dip_sw[15:8];  // DIP switch 2 (active low)
wire [7:0] in0_data  = 8'hFF;          // Coins/start (all inactive for now)
wire [7:0] in1_data  = 8'hFF;          // P1 controls (all inactive)
wire [7:0] in2_data  = 8'hFF;          // P2 controls (all inactive)

wire [7:0] z80_Din = ~n_cs_mainrom   ? mainrom_D:
                     ~n_cs_bankrom   ? bank_rom_D:
                     ~n_cs_workram   ? workram_D:
                     ~n_cs_workram2  ? workram2_D:
                     ~n_cs_videoram  ? videoram_D:
                     cs_palette      ? palette_D:
                     cs_scroll       ? scroll_reg:
                     cs_watchdog     ? 8'hFF:
                     cs_dsw1         ? dsw1_data:
                     cs_dsw2         ? dsw2_data:
                     cs_in0          ? in0_data:
                     cs_in1          ? in1_data:
                     cs_in2          ? in2_data:
                     8'hFF;

//------------------------------------------------------- Main program ROMs ----------------------------------------------------//

//Main program ROMs (m1.1h through j6.6h, 6x 4KB = 24KB at 0xA000-0xFFFF)
wire [7:0] rom_m1_D, rom_m2_D, rom_m3_D, rom_m4_D, rom_m5_D, rom_m6_D;

wire [7:0] mainrom_D = (z80_A[15:12] == 4'hA) ? rom_m1_D :
                       (z80_A[15:12] == 4'hB) ? rom_m2_D :
                       (z80_A[15:12] == 4'hC) ? rom_m3_D :
                       (z80_A[15:12] == 4'hD) ? rom_m4_D :
                       (z80_A[15:12] == 4'hE) ? rom_m5_D :
                       (z80_A[15:12] == 4'hF) ? rom_m6_D :
                       8'hFF;

eprom_4k rom_m1 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m1_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m1_cs_i), .WR(ioctl_wr));
eprom_4k rom_m2 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m2_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m2_cs_i), .WR(ioctl_wr));
eprom_4k rom_m3 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m3_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m3_cs_i), .WR(ioctl_wr));
eprom_4k rom_m4 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m4_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m4_cs_i), .WR(ioctl_wr));
eprom_4k rom_m5 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m5_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m5_cs_i), .WR(ioctl_wr));
eprom_4k rom_m6 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(rom_m6_D),
                 .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                 .CS_DL(rom_m6_cs_i), .WR(ioctl_wr));

//------------------------------------------------------ Banked graphics ROMs --------------------------------------------------//

//Banked graphics ROMs (c1.1i through c9.9i, 9x 4KB)
//Bank select register chooses which 4KB bank is visible at 0x9000-0x9FFF
wire [7:0] bank0_D, bank1_D, bank2_D, bank3_D, bank4_D;
wire [7:0] bank5_D, bank6_D, bank7_D, bank8_D;

wire [7:0] bank_rom_D = (rom_bank == 4'd0) ? bank0_D :
                        (rom_bank == 4'd1) ? bank1_D :
                        (rom_bank == 4'd2) ? bank2_D :
                        (rom_bank == 4'd3) ? bank3_D :
                        (rom_bank == 4'd4) ? bank4_D :
                        (rom_bank == 4'd5) ? bank5_D :
                        (rom_bank == 4'd6) ? bank6_D :
                        (rom_bank == 4'd7) ? bank7_D :
                        (rom_bank == 4'd8) ? bank8_D :
                        8'hFF;

eprom_4k bank0 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank0_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank0_cs_i), .WR(ioctl_wr));
eprom_4k bank1 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank1_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank1_cs_i), .WR(ioctl_wr));
eprom_4k bank2 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank2_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank2_cs_i), .WR(ioctl_wr));
eprom_4k bank3 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank3_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank3_cs_i), .WR(ioctl_wr));
eprom_4k bank4 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank4_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank4_cs_i), .WR(ioctl_wr));
eprom_4k bank5 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank5_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank5_cs_i), .WR(ioctl_wr));
eprom_4k bank6 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank6_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank6_cs_i), .WR(ioctl_wr));
eprom_4k bank7 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank7_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank7_cs_i), .WR(ioctl_wr));
eprom_4k bank8 (.ADDR(z80_A[11:0]), .CLK(clk_49m), .DATA(bank8_D),
                .ADDR_DL(ioctl_addr), .CLK_DL(clk_49m), .DATA_IN(ioctl_data),
                .CS_DL(bank8_cs_i), .WR(ioctl_wr));

//------------------------------------------------------------ RAM ------------------------------------------------------------//

//Work RAM (0x8000-0x87FF, 2KB)
wire [7:0] workram_D;
dpram_dc #(.widthad_a(11)) workram
(
	.clock_a(clk_49m),
	.wren_a(~n_cs_workram & ~cpu_RnW),
	.address_a(z80_A[10:0]),
	.data_a(z80_Dout),
	.q_a(workram_D),

	.clock_b(clk_49m),
	.wren_b(hs_write),
	.address_b(hs_address),
	.data_b(hs_data_in),
	.q_b(hs_data_out)
);

//Work RAM expansion (0x8800-0x8FFF, 2KB)
wire [7:0] workram2_D;
spram #(8, 11) workram2
(
	.clk(clk_49m),
	.we(~n_cs_workram2 & ~cpu_RnW),
	.addr(z80_A[10:0]),
	.data(z80_Dout),
	.q(workram2_D)
);

// Scroll register (0x8100, 1 byte readable/writable)
reg [7:0] scroll_reg = 8'd0;
always_ff @(posedge clk_49m) begin
	if(cen_6m && cs_scroll && ~cpu_RnW)
		scroll_reg <= z80_Dout;
end

// Palette RAM (0x8000-0x800F, 16 bytes)
wire [7:0] palette_D;
spram #(8, 4) palette_ram
(
	.clk(clk_49m),
	.we(cs_palette && ~cpu_RnW),
	.addr(z80_A[3:0]),
	.data(z80_Dout),
	.q(palette_D)
);

//Video RAM (0x0000-0x7FFF, 32KB) - dual port: A=CPU, B=video scanout
wire [7:0] videoram_D;
wire [7:0] videoram_vout;
wire [14:0] vram_rd_addr = {v_cnt[7:0], h_cnt[7:1]}; // y*128 + x/2

dpram_dc #(.widthad_a(15)) videoram
(
	.clock_a(clk_49m),
	.address_a(z80_A[14:0]),
	.data_a(z80_Dout),
	.wren_a(~n_cs_videoram & ~cpu_RnW),
	.q_a(videoram_D),

	.clock_b(clk_49m),
	.address_b(vram_rd_addr),
	.q_b(videoram_vout)
);

//--------------------------------------------------------- Main latch ---------------------------------------------------------//

reg nmi_mask = 0;
reg flip = 0;
reg cs_soundirq = 0;
reg pixel_en = 0;
always_ff @(posedge clk_49m) begin
	if(!reset) begin
		nmi_mask <= 0;
		flip <= 0;
		cs_soundirq <= 0;
	end
	else if(cen_3m) begin
		if(cs_mainlatch)
//			case(z80_A[3:1])
            case(z80_A[2:0])								// Fixes
				3'b000: nmi_mask <= z80_Dout[0];
				3'b001: flip <= z80_Dout[0];
				3'b010: cs_soundirq <= z80_Dout[0];
				3'b100: pixel_en <= z80_Dout[0];
				default:;
		endcase
	end
end

//Generate VBlank NMI for MC6809E
reg n_nmi = 1;
always_ff @(posedge clk_49m) begin
	if(cen_6m) begin
//		if(!nmi_mask)
//			n_nmi <= 1;
//		else if(vblank_irq_en)
	    // Keep NMI inactive unless we are issuing a one-cycle VBlank pulse.
		n_nmi <= 1;
		if(nmi_mask && vblank_irq_en)
			n_nmi <= 0;
	end
end

//-------------------------------------------------------- Video timing --------------------------------------------------------//

//Konami 082 custom chip - responsible for all video timings
wire vblk, vblank_irq_en, h256;
wire [8:0] h_cnt;
wire [7:0] v_cnt;
k082 F5
(
	.reset(1),
	.clk(clk_49m),
	.cen(cen_6m),
	.h_center(h_center),
	.v_center(v_center),
	.n_vsync(video_vsync),
	.sync(video_csync),
	.n_hsync(video_hsync),
	.vblk(vblk),
	.vblk_irq_en(vblank_irq_en),
	.h1(h_cnt[0]),
	.h2(h_cnt[1]),
	.h4(h_cnt[2]),
	.h8(h_cnt[3]),
	.h16(h_cnt[4]),
	.h32(h_cnt[5]),
	.h64(h_cnt[6]),
	.h128(h_cnt[7]),
	.n_h256(h_cnt[8]),
	.h256(h256),
	.v1(v_cnt[0]),
	.v2(v_cnt[1]),
	.v4(v_cnt[2]),
	.v8(v_cnt[3]),
	.v16(v_cnt[4]),
	.v32(v_cnt[5]),
	.v64(v_cnt[6]),
	.v128(v_cnt[7])
);

//----------------------------------------------------- Final video output -----------------------------------------------------//

//Generate HBlank (active high) while the horizontal counter is between 141 and 268
wire hblk = (h_cnt > 140 && h_cnt < 269);

// Framebuffer pixel extraction: 4-bit packed pixels, 2 per byte
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];

// Direct grayscale mapping from pixel index (palette lookup in later phase)
assign red   = {pixel_index, 1'b0};
assign green = {pixel_index, 1'b0};
assign blue  = {pixel_index, 1'b0};

endmodule
