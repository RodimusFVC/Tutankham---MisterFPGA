# Tutankham FPGA - Comprehensive Bug Analysis & Fixes

## Cross-reference: Current RTL vs MAME source (tutankhm.cpp / tutankhm_v.cpp)

Below is every bug I've found comparing your current `Tutankham_CPU.sv` against the
known-working MAME implementation line by line. Fixes are ordered by severity — the
first two are almost certainly why you're getting a black screen.

---

## BUG 1 (CRITICAL — BLACK SCREEN ROOT CAUSE): IRQ is wired wrong — CPU never runs

**Location:** `Tutankham_CPU.sv`, MC6809E instantiation

```verilog
// CURRENT (BROKEN):
.nIRQ(1'b1),
.nFIRQ(1'b1),
```

**Problem:** Tutankham uses **IRQ** (active-low, directly from the LS259 mainlatch bit 0),
not NMI. Look at the MAME source:

```cpp
// MAME — tutankhm.cpp:
void tutankhm_state::vblank_irq(int state)
{
    if (state) {
        m_irq_toggle ^= 1;
        if (m_irq_toggle && m_irq_enable)
            m_maincpu->set_input_line(0, ASSERT_LINE);  // IRQ line 0
    }
}

void tutankhm_state::irq_enable_w(int state)
{
    m_irq_enable = state;
    if (!m_irq_enable)
        m_maincpu->set_input_line(0, CLEAR_LINE);
}
```

The 6809's line 0 = IRQ. **Not NMI, not FIRQ.** The game software uses IRQ as the
main vblank interrupt. NMI is not used at all by Tutankham.

Your current code ties `nIRQ` permanently HIGH (inactive), so the CPU boots, maybe
runs a few instructions, but **never gets a vblank IRQ** to drive the game loop. The
game initializes, waits for a vblank interrupt, and hangs forever. Black screen.

The LS259 mainlatch bit 0 = `irq_enable`. When enabled AND vblank fires, IRQ is
asserted. When the game writes 0 to mainlatch bit 0, IRQ is cleared.

Your current `nmi_mask` variable is actually the IRQ enable. The whole NMI logic
path you have is wrong — it should be IRQ.

**Fix:** Replace the NMI-based interrupt with IRQ-based, matching MAME's toggle behavior:

```verilog
// Replace nmi_mask with irq_enable, add irq_toggle
reg irq_enable = 0;
reg irq_toggle = 0;
reg n_irq = 1;

// In the mainlatch case statement, bit 0 becomes:
3'b000: begin
    irq_enable <= z80_Dout[0];
    if (!z80_Dout[0])
        n_irq <= 1;  // Clear IRQ when disabled (matches MAME)
end

// VBlank IRQ generation — every other frame, matching MAME:
always_ff @(posedge clk_49m) begin
    if (!reset) begin
        irq_toggle <= 0;
        n_irq <= 1;
    end
    else if (cen_6m) begin
        if (vblank_irq_en) begin
            irq_toggle <= ~irq_toggle;
            if (~irq_toggle && irq_enable)  // toggle goes 0->1, AND enabled
                n_irq <= 0;                  // Assert IRQ
        end
    end
end

// MC6809E instantiation:
.nIRQ(n_irq),
.nFIRQ(1'b1),
.nNMI(1'b1),    // NMI not used by Tutankham
```

---

## BUG 2 (CRITICAL): Address decode overlap — I/O registers hidden by workram

**Location:** `Tutankham_CPU.sv`, address decoding + data mux

```verilog
// CURRENT:
wire n_cs_workram  = ~(z80_A[15:11] == 5'b10000);  // 0x8000-0x87FF
```

This decodes ALL of `0x8000-0x87FF` as work RAM. But the I/O registers (palette at
`0x8000-0x800F`, scroll at `0x8100`, watchdog at `0x8120`, DIP switches at `0x8160`,
inputs at `0x8180/81A0/81C0/81E0`, mainlatch at `0x8200-0x8207`, banksel at `0x8300`,
sound at `0x8600/0x8700`) are all within that same range!

In MAME:
```cpp
map(0x0000, 0x7fff).ram().share(m_videoram);
map(0x8000, 0x800f).mirror(0x00f0).ram().w(palette...)  // NO separate work RAM block
map(0x8100, 0x8100).mirror(0x000f).ram().share(m_scroll);
// ... I/O at 0x8120-0x8700 ...
map(0x8800, 0x8fff).ram();  // THIS is the actual "work RAM"
map(0x9000, 0x9fff).bankr(m_mainbank);
map(0xa000, 0xffff).rom();
```

**There is NO work RAM at `0x8000-0x87FF`!** That entire region is I/O.
The palette at `0x8000-0x800F` is mirrored through `0x80FF` (that's the
`.mirror(0x00f0)`). The only actual RAM in the `0x8xxx` range is at `0x8800-0x8FFF`.

Your data mux puts `workram` higher priority than the I/O chip selects in the
`z80_Din` chain. So even though `cs_palette`, `cs_scroll`, etc. are decoded correctly,
the CPU **reads work RAM data instead of I/O registers** because `~n_cs_workram`
is true for the entire `0x8000-0x87FF` range and appears first in the mux.

**Fix:** Remove the work RAM from `0x8000-0x87FF` entirely. The "work RAM" mapping
should not exist there — the I/O decode already covers what the game needs. The
actual work RAM at `0x8800-0x8FFF` (`workram2`) is correct.

If you want to keep `workram` for hiscore support at addresses that don't conflict,
you need to exclude the I/O region. But the cleanest fix matching MAME is:

```verilog
// Remove n_cs_workram entirely, or restrict it to never match:
// There is NO general work RAM at 0x8000-0x87FF in Tutankham.
// The palette (0x8000-0x80FF with mirror) acts as the only "RAM" in that region.

// Fix the data mux — I/O must take priority:
wire [7:0] z80_Din = cs_palette      ? palette_D :
                     cs_scroll       ? scroll_reg :
                     cs_watchdog     ? 8'hFF :
                     cs_dsw2         ? dsw2_data :
                     cs_in0          ? in0_data :
                     cs_in1          ? in1_data :
                     cs_in2          ? in2_data :
                     cs_dsw1         ? dsw1_data :
                     ~n_cs_workram2  ? workram2_D :
                     ~n_cs_bankrom   ? bank_rom_D :
                     ~n_cs_mainrom   ? mainrom_D :
                     ~n_cs_videoram  ? videoram_D :
                     8'hFF;
```

For hiscore support, connect it to `workram2` (the `0x8800-0x8FFF` RAM) instead.

---

## BUG 3 (MAJOR): Palette not wired to video output

**Location:** `Tutankham_CPU.sv`, final video output

```verilog
// CURRENT (grayscale only):
assign red   = {pixel_index, 1'b0};
assign green = {pixel_index, 1'b0};
assign blue  = {pixel_index, 1'b0};
```

The palette RAM exists but is never read for video scanout. You need a dual-port
palette or register file.

From MAME's `raw_to_rgb_func`:
```
bit 0 -- 1 kohm resistor  -- RED
bit 1 -- 470 ohm resistor -- RED
bit 2 -- 220 ohm resistor -- RED
bit 3 -- 1 kohm resistor  -- GREEN
bit 4 -- 470 ohm resistor -- GREEN
bit 5 -- 220 ohm resistor -- GREEN
bit 6 -- 470 ohm resistor -- BLUE
bit 7 -- 220 ohm resistor -- BLUE
```

Format: `BBGGGRRR` — 3 bits red (bits 2:0), 3 bits green (bits 5:3), 2 bits blue (bits 7:6).

**Fix:** Replace `spram` palette with a register file for simultaneous CPU write + video read:

```verilog
// Palette register file (16 entries, 8 bits each)
reg [7:0] palette_regs [0:15];
always_ff @(posedge clk_49m) begin
    if (cs_palette && ~cpu_RnW)
        palette_regs[z80_A[3:0]] <= z80_Dout;
end
wire [7:0] palette_D = palette_regs[z80_A[3:0]];  // CPU read path

// Video scanout — look up pixel_index in palette
wire [7:0] pal_byte = palette_regs[pixel_index];

// Resistor-weighted RGB conversion (BBGGGRRR -> 5-bit per channel)
// Using simplified weights that match the Galaxian resistor network
assign red   = {pal_byte[2:0], pal_byte[2:1]};   // 3-bit R → 5-bit
assign green = {pal_byte[5:3], pal_byte[5:4]};   // 3-bit G → 5-bit
assign blue  = {pal_byte[7:6], pal_byte[7:6], pal_byte[7]};  // 2-bit B → 5-bit
```

Remove the old `spram #(8, 4) palette_ram` block.

---

## BUG 4 (MAJOR): Mainlatch decode uses wrong address bits

**Location:** `Tutankham_CPU.sv`, mainlatch decode

```verilog
// CURRENT:
wire cs_mainlatch = (z80_A[15:3] == 13'h1040) & ~cpu_RnW;  // 0x8200-0x8207
```

`13'h1040` = `1_0000_0100_0000` in binary. For this to match `z80_A[15:3]`:
- z80_A[15:3] = 13'h1040 means z80_A = 0x8200-0x8207. **This looks correct.**

But in the case statement:

```verilog
case(z80_A[2:0])         // Fixes
    3'b000: nmi_mask <= ...   // 0x8200 → bit 0
    3'b001: flip <= ...       // 0x8201 → bit 1
    3'b010: cs_soundirq <= ...// 0x8202 → bit 2
    3'b100: pixel_en <= ...   // 0x8204 → bit 4
```

Compare with MAME's LS259 assignments:
```
bit 0: irq_enable       (0x8200)
bit 1: PAY OUT (unused)  (0x8201)
bit 2: coin_counter_2    (0x8202)
bit 3: coin_counter_1    (0x8203)
bit 4: stars_enable      (0x8204)
bit 5: mute              (0x8205)
bit 6: flip_screen_x     (0x8206)
bit 7: flip_screen_y     (0x8207)
```

So your mapping is actually OK for the case bits (using z80_A[2:0] is correct for
this LS259). But you named it `nmi_mask` when it should be `irq_enable` — see Bug 1.
Also `cs_soundirq` at bit 2 is wrong — bit 2 is `coin_counter_2`, not sound IRQ.

The sound trigger is at `0x8600`:
```cpp
// MAME:
map(0x8600, 0x8600).mirror(0x00ff).w(FUNC(tutankhm_state::sound_on_w));
```
And `sound_on_w` does `sh_irqtrigger_w(0); sh_irqtrigger_w(1);` — a pulse.

Your current code has sound IRQ as a latch bit in the mainlatch, which is wrong.

**Fix:** Correct the mainlatch assignments:

```verilog
reg irq_enable = 0;     // bit 0
reg coin_counter2 = 0;  // bit 2
reg coin_counter1 = 0;  // bit 3
reg stars_enable = 0;   // bit 4
reg sound_mute = 0;     // bit 5
reg flip_x = 0;         // bit 6
reg flip_y = 0;         // bit 7

always_ff @(posedge clk_49m) begin
    if (!reset) begin
        irq_enable <= 0;
        flip_x <= 0;
        flip_y <= 0;
    end
    else if (cen_3m && cs_mainlatch) begin
        case(z80_A[2:0])
            3'b000: begin
                irq_enable <= z80_Dout[0];
                if (!z80_Dout[0]) n_irq <= 1;
            end
            3'b001: ;  // PAY OUT — unused
            3'b010: coin_counter2 <= z80_Dout[0];
            3'b011: coin_counter1 <= z80_Dout[0];
            3'b100: stars_enable <= z80_Dout[0];
            3'b101: sound_mute <= z80_Dout[0];
            3'b110: flip_x <= z80_Dout[0];
            3'b111: flip_y <= z80_Dout[0];
        endcase
    end
end
```

---

## BUG 5 (MAJOR): Sound IRQ trigger is wrong

**Location:** `Tutankham_CPU.sv`, sound IRQ generation

The sound trigger in MAME is at `0x8600` and does a 0→1 pulse:
```cpp
void tutankhm_state::sound_on_w(uint8_t data)
{
    m_timeplt_audio->sh_irqtrigger_w(0);
    m_timeplt_audio->sh_irqtrigger_w(1);
}
```

Your current code ties `cs_soundirq` to mainlatch bit 2 (wrong register entirely)
and latches it as a level rather than generating a pulse.

**Fix:** Generate a one-shot pulse when the CPU writes to `0x8600`:

```verilog
wire cs_soundon = (z80_A[15:8] == 8'h86) & ~cpu_RnW;  // Already exists

// Sound IRQ trigger — pulse on write to 0x8600
reg sound_irq_r = 0;
always_ff @(posedge clk_49m) begin
    if (!reset)
        sound_irq_r <= 0;
    else if (cen_3m) begin
        if (cs_soundon)
            sound_irq_r <= 1;
        else
            sound_irq_r <= 0;
    end
end
assign irq_trigger = sound_irq_r;
```

---

## BUG 6 (MODERATE): Controls hardcoded — game can't coin up or start

**Location:** `Tutankham_CPU.sv`

```verilog
wire [7:0] in0_data = 8'hFF;  // All inactive
wire [7:0] in1_data = 8'hFF;
wire [7:0] in2_data = 8'hFF;
```

The `controls_dip` input from the sound board is available but unused. The sound
board already handles muxing controls based on `cs_controls_dip1`, `cs_dip2`,
`cpubrd_A5`, and `cpubrd_A6`.

**Fix:** Route `controls_dip` into the data mux for the control/DIP addresses:

```verilog
// Remove the hardcoded in0/in1/in2 wires and use controls_dip from sound board:
wire [7:0] z80_Din = cs_palette      ? palette_D :
                     cs_scroll       ? scroll_reg :
                     cs_watchdog     ? 8'hFF :
                     (cs_dsw2 | cs_in0 | cs_in1 | cs_in2 | cs_dsw1) ? controls_dip :
                     ~n_cs_workram2  ? workram2_D :
                     ~n_cs_bankrom   ? bank_rom_D :
                     ~n_cs_mainrom   ? mainrom_D :
                     ~n_cs_videoram  ? videoram_D :
                     8'hFF;
```

---

## BUG 7 (MODERATE): CPU clock may be too fast

**Location:** `Tutankham_CPU.sv`, E/Q clock generation

The Tutankham CPU board uses an **18.432 MHz** crystal (see MAME source header).
The 6809E runs at 18.432MHz / 12 = **1.536 MHz**.

Your code uses 49.152 MHz master and divides by 32 (`cpu_div` is 5 bits):
49.152 / 32 = 1.536 MHz. **This is correct.** ✓

However, verify that the `cpu_div` counter doesn't conflict with the `div` counter
used for `cen_6m`/`cen_3m`. They're independent, which should be fine.

---

## BUG 8 (MINOR): Scroll register not applied to VRAM addressing

**Location:** `Tutankham_CPU.sv`, VRAM read address

```verilog
wire [14:0] vram_rd_addr = {v_cnt[7:0], h_cnt[7:1]};
```

MAME applies scroll to the Y coordinate:
```cpp
uint8_t const yscroll = (effx < 192 && m_scroll.found()) ? *m_scroll : 0;
uint8_t const effy = (y ^ xory) + yscroll;
uint8_t const vrambyte = m_videoram[effy * 128 + effx / 2];
```

Scroll is added to the Y (vertical) coordinate, but only when `effx < 192`.
Not critical for initial bring-up but needed for correct scrolling.

**Fix (apply after basic video works):**
```verilog
wire [7:0] scroll_y = (h_cnt[7:0] < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = v_cnt[7:0] + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, h_cnt[7:1]};
```

---

## BUG 9 (MINOR): h_cnt[8] is inverted via n_h256

**Location:** `Tutankham_CPU.sv`, k082 connection

```verilog
.n_h256(h_cnt[8]),
```

The k082 module outputs `h256 = ~h_cnt[8]` and `n_h256 = h_cnt[8]`. So `h_cnt[8]`
in your module is actually the **inverted** H256. This means `h_cnt[8:0]` doesn't
form a normal 9-bit counter — bit 8 is inverted relative to bits 7:0.

This affects the VRAM address and HBlank calculations. During the visible portion
(h_cnt 0-255 from k082 perspective), h_cnt[8] = n_h256 = 1 (since the k082 counter
runs 128-511, and h256 = ~h_cnt_internal[8]).

Looking at k082: the counter runs 0→511, resets to 128. So during visible area
(roughly 128-383), h_cnt_internal[8] transitions at 256. h256 = ~h_cnt[8], so
when internal counter is 128-255, h_cnt_internal[8]=0, h256=1, n_h256=0.
When internal counter is 256-383, h_cnt_internal[8]=1, h256=0, n_h256=1.

So your `h_cnt[8]` = n_h256 = h_cnt_internal[8]. The VRAM address only uses
`h_cnt[7:1]` which comes from h1-h128, so this is fine for VRAM. But verify your
HBlank range accounts for the counter starting at 128.

---

## Summary — Priority Order for Black Screen Fix

1. **Bug 1** — Wire IRQ instead of NMI. This is almost certainly THE reason for black screen.
   Without vblank IRQs, the game hangs immediately after boot.

2. **Bug 2** — Fix address decode overlap so I/O registers are accessible.
   Without this, the CPU can't read controls/DIPs and can't write palette correctly.

3. **Bug 3** — Wire palette to video output for color display.

4. **Bug 4+5** — Fix mainlatch assignments and sound trigger.

5. **Bug 6** — Wire controls for interactivity.

6. **Bug 8** — Apply scroll for correct gameplay graphics.
