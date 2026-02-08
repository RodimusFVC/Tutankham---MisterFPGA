# Tutankham FPGA Fix Instructions for Claude Code

## File to edit: `rtl/Tutankham_CPU.sv`

Apply these changes in order. Each section describes what to find and what to replace it with.

---

## CHANGE 1: Replace NMI interrupt system with IRQ (matching MAME)

### Find the mainlatch register declarations and replace:

FIND:
```
reg nmi_mask = 0;
reg flip = 0;
reg cs_soundirq = 0;
reg pixel_en = 0;
```

REPLACE WITH:
```
reg irq_enable = 0;
reg flip_x = 0;
reg flip_y = 0;
reg stars_enable = 0;
reg sound_mute = 0;
```

### Find the mainlatch case block and replace:

FIND (the entire always_ff block containing the mainlatch case):
```
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
```

REPLACE WITH:
```
always_ff @(posedge clk_49m) begin
	if(!reset) begin
		irq_enable <= 0;
		flip_x <= 0;
		flip_y <= 0;
		stars_enable <= 0;
		sound_mute <= 0;
	end
	else if(cen_3m) begin
		if(cs_mainlatch)
			case(z80_A[2:0])
				3'b000: begin  // IRQ enable (LS259 Q0)
					irq_enable <= z80_Dout[0];
					if(!z80_Dout[0])
						n_irq <= 1;  // Clear IRQ when disabled
				end
				3'b001: ;  // PAY OUT - unused
				3'b010: ;  // Coin counter 2
				3'b011: ;  // Coin counter 1
				3'b100: stars_enable <= z80_Dout[0];  // Stars enable (LS259 Q4)
				3'b101: sound_mute <= z80_Dout[0];    // Sound mute (LS259 Q5)
				3'b110: flip_x <= z80_Dout[0];        // Flip screen X (LS259 Q6)
				3'b111: flip_y <= z80_Dout[0];        // Flip screen Y (LS259 Q7)
			endcase
	end
end
```

### Find the NMI generation block and replace with IRQ:

FIND (the entire VBlank NMI block — it spans two fragments):
```
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
```

REPLACE WITH:
```
//Generate VBlank IRQ for MC6809E (every other frame, per MAME)
reg n_irq = 1;
reg irq_toggle = 0;
reg vblank_irq_en_last = 0;
always_ff @(posedge clk_49m) begin
	if(!reset) begin
		n_irq <= 1;
		irq_toggle <= 0;
		vblank_irq_en_last <= 0;
	end
	else if(cen_6m) begin
		vblank_irq_en_last <= vblank_irq_en;
		// Detect rising edge of vblank_irq_en
		if(vblank_irq_en && !vblank_irq_en_last) begin
			irq_toggle <= ~irq_toggle;
			if(!irq_toggle && irq_enable)
				n_irq <= 0;  // Assert IRQ every other frame
		end
		// IRQ cleared when irq_enable is written to 0 (done in mainlatch above)
	end
end
```

### Fix the MC6809E instantiation — use IRQ instead of NMI:

FIND:
```
	.nIRQ(1'b1),
	.nFIRQ(1'b1),
	.nNMI(n_nmi),
```

REPLACE WITH:
```
	.nIRQ(n_irq),
	.nFIRQ(1'b1),
	.nNMI(1'b1),
```

---

## CHANGE 2: Fix address decode — remove work RAM from I/O region

### Find the workram chip select:

FIND:
```
wire n_cs_workram  = ~(z80_A[15:11] == 5'b10000);         // 0x8000-0x87FF (2KB work RAM)
```

REPLACE WITH:
```
// NOTE: There is no general work RAM at 0x8000-0x87FF in Tutankham.
// That region is entirely I/O (palette, scroll, controls, mainlatch, etc.)
// The only RAM in the 0x8xxx range is at 0x8800-0x8FFF (workram2).
// Keeping this wire for hiscore compatibility but it should never be used in the data mux.
wire n_cs_workram  = 1'b1;  // Disabled — no work RAM at 0x8000-0x87FF
```

### Fix the CPU data input mux — put I/O first, remove workram:

FIND:
```
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
```

REPLACE WITH:
```
// I/O registers must be checked first (they're in the 0x8000-0x87FF range)
// Controls/DIP data comes from the sound board via controls_dip
wire [7:0] z80_Din = cs_palette                              ? palette_D :
                     cs_scroll                               ? scroll_reg :
                     cs_watchdog                             ? 8'hFF :
                     (cs_dsw2 | cs_in0 | cs_in1 | cs_in2 | cs_dsw1) ? controls_dip :
                     ~n_cs_workram2                          ? workram2_D :
                     ~n_cs_bankrom                           ? bank_rom_D :
                     ~n_cs_mainrom                           ? mainrom_D :
                     ~n_cs_videoram                          ? videoram_D :
                     8'hFF;
```

### Remove the hardcoded input data wires (no longer needed):

FIND:
```
// Input data from controls (placeholder - proper wiring in Phase 5)
wire [7:0] dsw1_data = ~dip_sw[7:0];   // DIP switch 1 (active low)
wire [7:0] dsw2_data = ~dip_sw[15:8];  // DIP switch 2 (active low)
wire [7:0] in0_data  = 8'hFF;          // Coins/start (all inactive for now)
wire [7:0] in1_data  = 8'hFF;          // P1 controls (all inactive)
wire [7:0] in2_data  = 8'hFF;          // P2 controls (all inactive)
```

REPLACE WITH:
```
// Controls and DIP switch data comes from the sound board via controls_dip input.
// The sound board muxes the correct data based on cs_controls_dip1, cs_dip2,
// cpubrd_A5, and cpubrd_A6 signals.
```

---

## CHANGE 3: Replace palette RAM with register file + wire to video output

### Find the palette RAM instantiation:

FIND:
```
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
```

REPLACE WITH:
```
// Palette register file (0x8000-0x800F, 16 entries × 8 bits)
// Uses registers instead of SPRAM so video scanout can read simultaneously with CPU
reg [7:0] palette_regs [0:15];
initial begin
	integer i;
	for (i = 0; i < 16; i = i + 1)
		palette_regs[i] = 8'd0;
end
always_ff @(posedge clk_49m) begin
	if(cs_palette && ~cpu_RnW)
		palette_regs[z80_A[3:0]] <= z80_Dout;
end
wire [7:0] palette_D = palette_regs[z80_A[3:0]];  // CPU read-back path
```

### Find the final video output section and replace:

FIND:
```
// Framebuffer pixel extraction: 4-bit packed pixels, 2 per byte
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];

// Direct grayscale mapping from pixel index (palette lookup in later phase)
assign red   = {pixel_index, 1'b0};
assign green = {pixel_index, 1'b0};
assign blue  = {pixel_index, 1'b0};
```

REPLACE WITH:
```
// Framebuffer pixel extraction: 4-bit packed pixels, 2 per byte
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];

// Palette lookup — convert 4-bit pixel index to RGB via palette registers
// Palette byte format (Galaxian/Konami standard): BBGGGRRR
//   bits [2:0] = Red   (3 bits, through 1K/470/220 ohm resistors)
//   bits [5:3] = Green (3 bits, through 1K/470/220 ohm resistors)
//   bits [7:6] = Blue  (2 bits, through 470/220 ohm resistors)
wire [7:0] pal_byte = palette_regs[pixel_index];

// Expand to 5-bit per channel for MiSTer output
assign red   = {pal_byte[2:0], pal_byte[2:1]};                    // 3→5 bits
assign green = {pal_byte[5:3], pal_byte[5:4]};                    // 3→5 bits
assign blue  = {pal_byte[7:6], pal_byte[7:6], pal_byte[7]};      // 2→5 bits
```

---

## CHANGE 4: Fix sound IRQ trigger

### Find the sound_irq generation block:

FIND:
```
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
```

REPLACE WITH:
```
//Generate sound IRQ trigger — pulse on write to 0x8600 (matching MAME sound_on_w)
reg sound_irq = 0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		sound_irq <= 0;
	else if(cen_3m) begin
		if(cs_soundon)
			sound_irq <= 1;   // Assert for one cen_3m cycle
		else
			sound_irq <= 0;   // De-assert next cycle = pulse
	end
end
assign irq_trigger = sound_irq;
```

---

## CHANGE 5: Apply scroll register to VRAM address (for correct gameplay)

### Find the VRAM read address:

FIND:
```
wire [14:0] vram_rd_addr = {v_cnt[7:0], h_cnt[7:1]}; // y*128 + x/2
```

REPLACE WITH:
```
// Apply scroll offset to vertical coordinate (MAME: yscroll applied when effx < 192)
wire [7:0] scroll_y = (h_cnt[7:0] < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = v_cnt[7:0] + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, h_cnt[7:1]}; // (y+scroll)*128 + x/2
```

---

## CHANGE 6: Fix hiscore RAM connection (optional — after basic video works)

The hiscore system currently connects to `workram` at `0x8000-0x87FF` which we've
disabled. Reconnect it to `workram2` at `0x8800-0x8FFF`:

### Find the workram dpram_dc block:

FIND:
```
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
```

REPLACE WITH:
```
// Work RAM at 0x8000-0x87FF does not exist in Tutankham hardware.
// Hiscore support uses the 0x8800-0x8FFF work RAM (workram2) instead.
// Keeping a minimal stub for hiscore read-back:
assign hs_data_out = 8'h00;
```

Then convert `workram2` to dual-port for hiscore support:

FIND:
```
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
```

REPLACE WITH:
```
//Work RAM (0x8800-0x8FFF, 2KB) — the only general-purpose RAM in the I/O region
wire [7:0] workram2_D;
dpram_dc #(.widthad_a(11)) workram2
(
	.clock_a(clk_49m),
	.wren_a(~n_cs_workram2 & ~cpu_RnW),
	.address_a(z80_A[10:0]),
	.data_a(z80_Dout),
	.q_a(workram2_D),

	.clock_b(clk_49m),
	.wren_b(hs_write),
	.address_b(hs_address[10:0]),
	.data_b(hs_data_in),
	.q_b(hs_data_out)
);
```

---

## Verification checklist after applying fixes:

1. CPU should now receive vblank IRQs → game loop runs → writes to VRAM
2. Palette writes at 0x8000-0x800F should be visible (not hidden by workram)
3. Video output should show colored pixels from palette lookup
4. Controls should respond via sound board controls_dip path
5. Sound board should receive IRQ pulses when game triggers sound
