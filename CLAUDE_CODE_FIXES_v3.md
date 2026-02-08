# Tutankham FPGA Fix Instructions v3 — Upside Down, Shifted, No Sound

## File to edit: `rtl/Tutankham_CPU.sv`

---

## ISSUE 1: Game is upside down

The k082 counter outputs go through the VRAM address, and the MiSTer framework
handles rotation via `screen_rotate`. The top-level has `rotate_ccw = 0` which means
CW rotation is applied by the framework.

The problem is the VRAM Y coordinate. The k082 vertical counter runs from 248 up
through 511 (wrapping), then 0-271 for the visible region. The lower 8 bits
(`v_cnt[7:0]`) effectively run 0-255 during the visible area, but the game
software writes its framebuffer expecting Y=0 to be at the TOP of the (un-rotated)
screen.

In MAME, the screen is drawn with Y directly mapping to scanlines AND the game
is flagged ROT90. The MiSTer `screen_rotate` module handles the 90° rotation. But
the Y-to-VRAM mapping needs to match what the game expects.

Looking at MAME's rendering:
```cpp
uint8_t const effy = (y ^ xory) + yscroll;
uint8_t const vrambyte = m_videoram[effy * 128 + effx / 2];
```

Where `xory = m_flipscreen_y ? 255 : 0`. The game sets `flipscreen_y` for upright
cabinet mode. In your FPGA, `flip_y` gets set by mainlatch bit 7, but it's never
applied to the VRAM address.

**Fix:** Apply `flip_y` (and `flip_x`) to the VRAM read coordinates.

FIND:
```verilog
// Scroll applied to Y (MAME: yscroll when effx < 192, else 0)
wire [7:0] scroll_y = (h_cnt[7:0] < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = v_cnt[7:0] + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, h_cnt[7:1]};  // (y+scroll)*128 + x/2
```

REPLACE WITH:
```verilog
// Apply flip and scroll to VRAM read coordinates (matching MAME screen_update)
// flip_x XORs the X coordinate, flip_y XORs the Y coordinate
wire [7:0] eff_x = h_cnt[7:0] ^ {8{flip_x}};
wire [7:0] scroll_y = (eff_x < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = (v_cnt[7:0] ^ {8{flip_y}}) + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, eff_x[7:1]};  // (y^flip+scroll)*128 + (x^flip)/2
```

And update the pixel nibble select to use the flipped X:

FIND:
```verilog
wire [3:0] pixel_index = h_cnt[0] ? videoram_vout[7:4] : videoram_vout[3:0];
```

REPLACE WITH:
```verilog
wire [3:0] pixel_index = eff_x[0] ? videoram_vout[7:4] : videoram_vout[3:0];
```

NOTE: Make sure `eff_x` is declared BEFORE both the `vram_rd_addr` and the
`pixel_index` lines (i.e., move the flip/scroll block to before the VRAM
instantiation or at least before the pixel extraction).

---

## ISSUE 2: Graphics shifted 8-16 pixels (bottom row at top)

This is caused by the k082 horizontal counter not starting at 0. The k082 counter
runs from 128 to 511, then resets to 128. So during the visible area, `h_cnt[7:0]`
doesn't start at 0 — it starts at some offset.

The visible area (HBlank inactive) starts approximately when h_cnt reaches ~141
(based on `wire hblk = (h_cnt > 140 && h_cnt < 269)`). But h_cnt[7:0] at value
141 = 0x8D = 141. So the VRAM X coordinate fed to the framebuffer starts at 141,
not 0.

The game expects X=0 to map to the first visible pixel. The k082 counter's bit 7
(`h128`) is always 1 during the visible range (128-255), then wraps. So using
`h_cnt[7:0]` directly means X starts at ~141 instead of 0.

However, looking more carefully at MAME: it uses the raw x coordinate (0-255 for
the visible area, set by `GALAXIAN_HBEND=0` and `GALAXIAN_HBSTART=256`). The MAME
screen renderer iterates `x` from 0 to 255 for visible pixels. The k082 in hardware
produces pixel coordinates where the visible portion is mapped as h_cnt values
128-383 (of which 128-255 is one half and 256-383 is the other).

The real hardware uses the lower 8 bits of the horizontal counter as the X coordinate
into VRAM. Since the counter starts at 128, `h_cnt[7:0]` starts at `10000000` = 128.
The visible pixels from the game's perspective start at X=0.

**The fix depends on how the k082 counter maps to visible pixels.** The counter
value 128 corresponds to X=0 in the framebuffer. Since `h_cnt[7:0]` = 128 when
h_cnt = 128, and the visible area starts around h_cnt = 0 (after counter wraps
from 511 to 128)...

Actually, let me re-examine. The k082 source shows: counter starts at 0, counts to
511, resets to 128. Visible area is approximately h_cnt 0-127 and 128-255 (before
HBlank). Wait — looking at the actual k082 code:

```verilog
511: h_cnt <= 9'd128;  // wraps from 511 to 128
```

So the sequence is: ...509, 510, 511, 128, 129, 130, ... 509, 510, 511, 128, ...

The HBlank is at `h_cnt > 140 && h_cnt < 269`. So visible is either h_cnt <= 140
OR h_cnt >= 269. But the counter goes 128→511→128, so after 511→128, we get
128, 129, ..., 140 = 13 visible pixels, then 141-268 = HBlank, then 269-511 = 243
visible pixels. Total visible = 13 + 243 = 256. That checks out.

So visible pixels are: h_cnt 269-511 (first 243 pixels), then 128-140 (last 13 pixels).

The game framebuffer X coordinate should be: `h_cnt - 269` for h_cnt >= 269, wrapping
around. But more simply, since MAME just uses 0-255 linearly and the hardware
counter's lower 8 bits cycle through the same range...

Actually the simplest approach: **the h_cnt lower 8 bits during the visible window
naturally cover 0-255 when you account for the 9-bit counter behavior.** h_cnt 269
has `h_cnt[7:0]` = 13. h_cnt 511 has `h_cnt[7:0]` = 255. h_cnt 128 = `h_cnt[7:0]`
= 128. h_cnt 140 = 140.

So the X values fed to VRAM go: 13,14,...,255,128,129,...,140. That's NOT 0-255
linearly. This IS your shift problem.

**The correct fix: use a pixel counter that counts 0-255 during the visible window,
synchronized to HBlank.**

FIND the HBlank wire:
```verilog
wire hblk = (h_cnt > 140 && h_cnt < 269);
```

ADD after it:
```verilog
// Generate a 0-255 pixel X counter synchronized to the visible window
// Visible pixels: h_cnt 269-511 (243 px), then 128-140 (13 px) = 256 total
// Use h_cnt offset so pixel 0 aligns with h_cnt=269
wire [7:0] pix_x = h_cnt[7:0] - 8'd13;  // h_cnt=269 → 269[7:0]=13 → pix_x=0
```

Then use `pix_x` instead of `h_cnt[7:0]` in the VRAM address and pixel select:

REPLACE the flip/scroll/vram block (from Issue 1 fix) with:
```verilog
// Apply flip and scroll to VRAM read coordinates (matching MAME screen_update)
wire [7:0] eff_x = pix_x ^ {8{flip_x}};
wire [7:0] scroll_y = (eff_x < 8'd192) ? scroll_reg : 8'd0;
wire [7:0] eff_y = (v_cnt[7:0] ^ {8{flip_y}}) + scroll_y;
wire [14:0] vram_rd_addr = {eff_y, eff_x[7:1]};
```

And the pixel select:
```verilog
wire [3:0] pixel_index = eff_x[0] ? videoram_vout[7:4] : videoram_vout[3:0];
```

**IMPORTANT**: If the shift is still off by a few pixels after this, adjust the
offset constant. Try `8'd13`, `8'd14`, or `8'd12` until the columns align properly.
The exact value depends on pipeline delays in the VRAM read.

---

## ISSUE 3: No sound

The sound path has two signals from Tutankham_CPU to the sound board:
- `irq_trigger` — pulses to interrupt the sound Z80
- `cs_sounddata` — active when CPU writes sound command byte to 0x8700

Looking at the sound board code in `TimePilot_SND.sv`:

```verilog
// IRQ generation:
wire irq_clr = (~reset | ~(n_iorq | n_m1));
reg n_irq = 1;
always_ff @(posedge clk_49m or posedge irq_clr) begin
    if(irq_clr)
        n_irq <= 1;
    else if(cen_3m && irq_trigger)
        n_irq <= 0;
end
```

This latches IRQ low when `irq_trigger` is high during a `cen_3m` cycle, then
clears when the Z80 acknowledges (IORQ+M1). This needs `irq_trigger` to be a pulse
that is HIGH for at least one `cen_3m` cycle.

The sound data latch:
```verilog
reg [7:0] sound_D = 8'd0;
always_ff @(posedge clk_49m) begin
    if(!reset)
        sound_D <= 8'd0;
    else if(cen_3m && cs_sounddata)
        sound_D <= cpubrd_Din;
end
```

This latches `cpubrd_Din` when `cs_sounddata` is high during `cen_3m`.

Now let me check what's actually happening in the current code. The v2 fix changed
sound_irq to use `cs_soundon`. Let me verify the signal flow:

1. CPU writes to 0x8700 → `cs_soundcmd` goes high → `cs_sounddata` output goes high
   → sound board latches the data byte from `cpubrd_Dout`
2. CPU writes to 0x8600 → `cs_soundon` goes high → `sound_irq` pulses high for one
   `cen_3m` cycle → `irq_trigger` output goes to sound board → sound Z80 gets IRQ

**Potential problem:** The `cs_soundon` and `cs_soundcmd` signals are gated with
`~cpu_RnW`, which is correct (write-only). But `cs_soundcmd` is assigned to the
`cs_sounddata` output directly:

```verilog
assign cs_sounddata = cs_soundcmd;
```

And `cs_soundcmd = (z80_A[15:8] == 8'h87) & ~cpu_RnW`. This is combinational —
it's only high during the exact clock cycle the CPU is writing. But the sound board
latches on `cen_3m` which is only high every 16th clock. The `cs_sounddata` pulse
might be too narrow to catch a `cen_3m` edge.

**This is likely the main sound bug.** The CPU write cycle is only a few clocks wide,
but `cen_3m` ticks every 16 clocks (49.152MHz / 16 = 3.072MHz). The sound board's
latch only samples when `cen_3m` is active. If the CPU's write strobe doesn't
overlap with a `cen_3m` edge, the sound data and IRQ trigger get missed entirely.

**Fix for sound data:** Latch `cs_sounddata` and `cs_soundon` so they hold until the
sound board can sample them. In Tutankham_CPU.sv:

FIND:
```verilog
//Generate and output chip select for sound command
assign cs_sounddata = cs_soundcmd;
```

REPLACE WITH:
```verilog
// Latch sound command strobe — hold until sound board's cen_3m can sample it
// The CPU write is brief; the sound board samples on cen_3m which is every 16 clocks.
// We need to stretch the pulse so it's guaranteed to be seen.
reg cs_sounddata_latch = 0;
reg [3:0] snd_data_hold = 0;
always_ff @(posedge clk_49m) begin
    if(!reset) begin
        cs_sounddata_latch <= 0;
        snd_data_hold <= 0;
    end
    else begin
        if(cs_soundcmd) begin
            cs_sounddata_latch <= 1;
            snd_data_hold <= 4'd15;  // Hold for 16 clocks (guarantees one cen_3m)
        end
        else if(snd_data_hold > 0)
            snd_data_hold <= snd_data_hold - 4'd1;
        else
            cs_sounddata_latch <= 0;
    end
end
assign cs_sounddata = cs_sounddata_latch;
```

**Fix for sound IRQ:** Similarly stretch the `irq_trigger` pulse:

FIND (the v2 sound_irq block):
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

REPLACE WITH:
```verilog
// Sound IRQ trigger — stretch pulse so sound board's cen_3m can catch it
reg sound_irq = 0;
reg [3:0] snd_irq_hold = 0;
always_ff @(posedge clk_49m) begin
    if(!reset) begin
        sound_irq <= 0;
        snd_irq_hold <= 0;
    end
    else begin
        if(cs_soundon) begin
            sound_irq <= 1;
            snd_irq_hold <= 4'd15;
        end
        else if(snd_irq_hold > 0)
            snd_irq_hold <= snd_irq_hold - 4'd1;
        else
            sound_irq <= 0;
    end
end
assign irq_trigger = sound_irq;
```

---

## Summary of all changes for v3

1. **Upside down** → Apply `flip_x`/`flip_y` to VRAM read coordinates
2. **Shifted pixels** → Use `pix_x = h_cnt[7:0] - 8'd13` to align X=0 with first visible pixel
3. **No sound** → Stretch `cs_sounddata` and `irq_trigger` pulses to guarantee sound board catches them on its slower `cen_3m` clock

All three changes are in `rtl/Tutankham_CPU.sv` only.
