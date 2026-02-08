# Tutankham FPGA Fix Instructions v2 (fixes compile error)

## File to edit: `rtl/Tutankham_CPU.sv`

**The v1 instructions had a bug: `n_irq` was driven from TWO separate `always_ff` blocks
(one in mainlatch, one in VBlank IRQ gen). Quartus rejects multiple constant drivers.
This version consolidates all `n_irq` logic into a single `always_ff` block.**

Apply these changes in order. Each section describes what to find and replace.

---

## CHANGE 1: Replace mainlatch registers + NMI with IRQ system

### Step 1a: Replace the mainlatch register declarations

FIND:
```verilog
reg nmi_mask = 0;
reg flip = 0;
reg cs_soundirq = 0;
reg pixel_en = 0;
```

REPLACE WITH:
```verilog
reg irq_enable = 0;
reg flip_x = 0;
reg flip_y = 0;
reg stars_enable = 0;
reg sound_mute = 0;
```

### Step 1b: Replace the mainlatch always_ff block

FIND the entire block (it starts with `always_ff @(posedge clk_49m) begin` containing the mainlatch case, and ends just before the VBlank NMI comment):

```verilog
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
```verilog
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
				3'b000: irq_enable <= z80_Dout[0];   // LS259 Q0: IRQ enable
				3'b001: ;                              // LS259 Q1: PAY OUT (unused)
				3'b010: ;                              // LS259 Q2: Coin counter 2
				3'b011: ;                              // LS259 Q3: Coin counter 1
				3'b100: stars_enable <= z80_Dout[0];   // LS259 Q4: Stars enable
				3'b101: sound_mute <= z80_Dout[0];     // LS259 Q5: Sound mute
				3'b110: flip_x <= z80_Dout[0];         // LS259 Q6: Flip screen X
				3'b111: flip_y <= z80_Dout[0];         // LS259 Q7: Flip screen Y
			endcase
	end
end
```

### Step 1c: Replace the VBlank NMI block with a SINGLE IRQ block

FIND the entire VBlank NMI block (may look like the original or a partially-modified version — look for `n_nmi` or `n_irq` generation after the mainlatch):

```verilog
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

REPLACE WITH (this is the ONLY block that drives `n_irq` — no other block should touch it):
```verilog
//Generate VBlank IRQ for MC6809E
// MAME: IRQ fires every other vblank frame when irq_enable is set.
//       IRQ is cleared when irq_enable is written to 0.
// ALL n_irq logic is in this single always_ff to avoid multiple-driver errors.
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
		// Clear IRQ when irq_enable is turned off (matches MAME irq_enable_w)
		if(!irq_enable)
			n_irq <= 1;
		// Detect rising edge of vblank_irq_en pulse from k082
		else if(vblank_irq_en && !vblank_irq_en_last) begin
			irq_toggle <= ~irq_toggle;
			if(!irq_toggle)  // Fire on every other vblank
				n_irq <= 0;
		end
	end
end
```

### Step 1d: Fix the MC6809E instantiation

FIND:
```verilog
	.nIRQ(1'b1),
	.nFIRQ(1'b1),
	.nNMI(n_nmi),
```

REPLACE WITH:
```verilog
	.nIRQ(n_irq),
	.nFIRQ(1'b1),
	.nNMI(1'b1),
```

---

## CHANGE 2: Fix address decode — I/O must not be hidden by work RAM

### Step 2a: Disable work RAM at 0x8000-0x87FF

FIND:
```verilog
wire n_cs_workram  = ~(z80_A[15:11] == 5'b10000);         // 0x8000-0x87FF (2KB work RAM)
```

REPLACE WITH:
```verilog
// No general work RAM at 0x8000-0x87FF in Tutankham — that range is all I/O.
// Real RAM is only at 0x8800-0x8FFF (workram2).
wire n_cs_workram  = 1'b1;  // Permanently disabled
```

### Step 2b: Fix the CPU data input mux

FIND:
```verilog
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
```verilog
// I/O registers checked first (they live in the 0x8000-0x87FF region).
// Controls and DIP data comes from the sound board via controls_dip input.
wire [7:0] z80_Din = cs_palette                                          ? palette_D :
                     cs_scroll                                           ? scroll_reg :
                     cs_watchdog                                         ? 8'hFF :
                     (cs_dsw2 | cs_in0 | cs_in1 | cs_in2 | cs_dsw1)     ? controls_dip :
                     ~n_cs_workram2                                      ? workram2_D :
                     ~n_cs_bankrom                                       ? bank_rom_D :
                     ~n_cs_mainrom                                       ? mainrom_D :
                     ~n_cs_videoram                                      ? videoram_D :
                     8'hFF;
```

### Step 2c: Remove hardcoded input data wires

FIND:
```verilog
// Input data from controls (placeholder - proper wiring in Phase 5)
wire [7:0] dsw1_data = ~dip_sw[7:0];   // DIP switch 1 (active low)
wire [7:0] dsw2_data = ~dip_sw[15:8];  // DIP switch 2 (active low)
wire [7:0] in0_data  = 8'hFF;          // Coins/start (all inactive for now)
wire [7:0] in1_data  = 8'hFF;          // P1 controls (all inactive)
wire [7:0] in2_data  = 8'hFF;          // P2 controls (all inactive)
```

REPLACE WITH:
```verilog
// Controls and DIP switch data is muxed by the sound board and returned
// via the controls_dip input, based on cs_controls_dip1, cs_dip2, A5, A6.
```

---

## CHANGE 3: Palette register file + video output wiring

### Step 3a: Replace palette RAM with register file

FIND:
```verilog
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
```verilog
// Palette register file (0x8000-0x800F, 16 × 8-bit)
// Register file allows simultaneous CPU write and video scanout read.
reg [7:0] palette_regs [0:15];
integer pal_i;
initial for (pal_i = 0; pal_i < 16; pal_i = pal_i + 1) palette_regs[pal_i] = 8'd0;

always_ff @(posedge clk_49m) begin
	if(cs_palette && ~cpu_RnW)
		palette_regs[z80_A[3:0]] <= z80_Dout;
end
wire [7:0] palette_D = palette_regs[z80_A[3:0]];  // CPU read-back
```

### Step 3b: Replace video output with palette lookup

FIND:
```verilog
// Framebuffer pixel extraction: 4-bit packed pixels, 2 per byte
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];

// Direct grayscale mapping from pixel index (palette lookup in later phase)
assign red   = {pixel_index, 1'b0};
assign green = {pixel_index, 1'b0};
assign blue  = {pixel_index, 1'b0};
```

REPLACE WITH:
```verilog
// Framebuffer pixel extraction: 4-bit packed pixels, 2 per byte
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];

// Palette lookup: 4-bit index → 8-bit palette byte (BBGGGRRR Galaxian format)
//   bits [2:0] = Red   (3 bits: 1K, 470, 220 ohm)
//   bits [5:3] = Green (3 bits: 1K, 470, 220 ohm)
//   bits [7:6] = Blue  (2 bits: 470, 220 ohm)
wire [7:0] pal_byte = palette_regs[pixel_index];

assign red   = {pal_byte[2:0], pal_byte[2:1]};                // 3→5 bit
assign green = {pal_byte[5:3], pal_byte[5:4]};                // 3→5 bit
assign blue  = {pal_byte[7:6], pal_byte[7:6], pal_byte[7]};   // 2→5 bit
```

---

## CHANGE 4: Fix sound IRQ trigger

FIND:
```verilog
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
```verilog
// Sound IRQ trigger — pulse on CPU write to 0x8600 (MAME: sound_on_w does 0→1 pulse)
reg sound_irq = 0;
always_ff @(posedge clk_49m) begin
	if(!reset)
		sound_irq <= 0;
	else if(cen_3m) begin
		if(cs_soundon)
			sound_irq <= 1;
		else
			sound_irq <= 0;
	end
end
assign irq_trigger = sound_irq;
```

---

## CHANGE 5: Apply scroll to VRAM address

FIND:
```verilog
wire [14:0] vram_rd_addr = {v_cnt[7:0], h_cnt[7:1]}; // y*128 + x/2
```

REPLACE WITH:
```verilog
// Scroll applied to Y (MAME: yscroll when effx < 192, else 0)
wire [7:0] scroll_y = (h_cnt[7:0] < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = v_cnt[7:0] + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, h_cnt[7:1]};  // (y+scroll)*128 + x/2
```

---

## Post-apply checklist

After applying all changes, verify:
1. `n_irq` is ONLY driven in the single VBlank IRQ `always_ff` block (Change 1c). No other block should assign to `n_irq`.
2. `n_nmi` variable no longer exists anywhere (replaced by `n_irq`). The MC6809E `.nNMI` pin is tied to `1'b1`.
3. `nmi_mask` variable no longer exists (replaced by `irq_enable`).
4. `cs_soundirq` variable no longer exists (sound uses `cs_soundon` + pulse in Change 4).
5. The `z80_Din` mux no longer references `workram_D`, `in0_data`, `in1_data`, `in2_data`, `dsw1_data`, or `dsw2_data`.
6. No `spram #(8, 4) palette_ram` instantiation exists (replaced by register file).
7. `pixel_en` and `flip` variables no longer exist (replaced by `stars_enable`, `flip_x`, `flip_y`, etc.)

If Quartus still complains about `n_irq` multiple drivers, search the file for ALL occurrences of `n_irq <=` and make sure they are only inside the one block from Change 1c.
