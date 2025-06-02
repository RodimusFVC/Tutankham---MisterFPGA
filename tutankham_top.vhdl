library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tutankham_top is
    port (
        clk     : in std_logic;
        reset   : in std_logic;

        -- TODO: Video output ports
        -- TODO: Audio output ports
        -- TODO: I/O (controls, dip switches, etc.)
        -- TODO: Memory/ROM loading interface
        -- TODO: MiSTer SDRAM / VGA hooks
        -- TODO: Debug ports
        --
        -- For now, only basic structure
        dummy_out : out std_logic
    );
end entity;

architecture rtl of tutankham_top is

    ------------------------------------------------------------------------------
    -- Component: MC6809 Main CPU
    ------------------------------------------------------------------------------
    component mc6809 is
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            rw       : out std_logic;
            address  : out std_logic_vector(15 downto 0);
            data_in  : in  std_logic_vector(7 downto 0);
            data_out : out std_logic_vector(7 downto 0);
            halt     : in  std_logic;
            nmi      : in  std_logic;
            irq      : in  std_logic;
            firq     : in  std_logic
        );
    end component;

    ------------------------------------------------------------------------------
    -- Component: Z80 Sound CPU
    ------------------------------------------------------------------------------
    component z80 is
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            address  : out std_logic_vector(15 downto 0);
            data_in  : in  std_logic_vector(7 downto 0);
            data_out : out std_logic_vector(7 downto 0);
            mreq     : out std_logic;
            iorq     : out std_logic;
            rd       : out std_logic;
            wr       : out std_logic;
            int      : in  std_logic;
            nmi      : in  std_logic
        );
    end component;

    -- Signals for MC6809
    signal m6809_address  : std_logic_vector(15 downto 0);
    signal m6809_data_in  : std_logic_vector(7 downto 0);
    signal m6809_data_out : std_logic_vector(7 downto 0);
    signal m6809_rw       : std_logic;
    signal m6809_irq      : std_logic := '0';
    signal m6809_firq     : std_logic := '0';
    signal m6809_nmi      : std_logic := '0';
    signal m6809_halt     : std_logic := '0';

    -- Signals for Z80
    signal z80_address  : std_logic_vector(15 downto 0);
    signal z80_data_in  : std_logic_vector(7 downto 0);
    signal z80_data_out : std_logic_vector(7 downto 0);
    signal z80_mreq     : std_logic;
    signal z80_iorq     : std_logic;
    signal z80_rd       : std_logic;
    signal z80_wr       : std_logic;
    signal z80_int      : std_logic := '0';
    signal z80_nmi      : std_logic := '0';

begin

    ------------------------------------------------------------------------------
    -- Instantiate MC6809 CPU
    ------------------------------------------------------------------------------
    main_cpu : mc6809
        port map (
            clk      => clk,
            reset    => reset,
            rw       => m6809_rw,
            address  => m6809_address,
            data_in  => m6809_data_in,
            data_out => m6809_data_out,
            halt     => m6809_halt,
            nmi      => m6809_nmi,
            irq      => m6809_irq,
            firq     => m6809_firq
        );

    ------------------------------------------------------------------------------
    -- Instantiate Z80 CPU
    ------------------------------------------------------------------------------
    sound_cpu : z80
        port map (
            clk      => clk,
            reset    => reset,
            address  => z80_address,
            data_in  => z80_data_in,
            data_out => z80_data_out,
            mreq     => z80_mreq,
            iorq     => z80_iorq,
            rd       => z80_rd,
            wr       => z80_wr,
            int      => z80_int,
            nmi      => z80_nmi
        );

    dummy_out <= '0';

end architecture;

architecture Behavioral of tutankham_top is

    signal cpu_addr      : STD_LOGIC_VECTOR(15 downto 0);
    signal cpu_data_in   : STD_LOGIC_VECTOR(7 downto 0);
    signal cpu_data_out  : STD_LOGIC_VECTOR(7 downto 0);
    signal cpu_rw        : STD_LOGIC;

    -- Address decode signals
    signal rom_sel         : STD_LOGIC;
    signal ram_sel         : STD_LOGIC;
    signal video_ram_sel   : STD_LOGIC;
    signal color_ram_sel   : STD_LOGIC;
    signal sprite_ram_sel  : STD_LOGIC;
    signal io_sel          : STD_LOGIC;
    signal bank_sel        : STD_LOGIC;

begin

    -- Basic memory map decode based on MAME:
    -- $0000-$7FFF: Main ROM
    -- $8000-$83FF: Main RAM
    -- $8400-$87FF: Video RAM
    -- $8800-$8BFF: Color RAM
    -- $8C00-$8FFF: Sprite RAM
    -- $9000-$93FF: Scroll/IO
    -- $A000-$FFFF: Banked ROM

    rom_sel        <= '1' when (cpu_addr(15 downto 14) = "00") else '0';                -- $0000-$3FFF
    bank_sel       <= '1' when (cpu_addr(15 downto 13) = "101") else '0';               -- $A000-$FFFF
    ram_sel        <= '1' when cpu_addr(15 downto 10) = "100000" else '0';              -- $8000-$83FF
    video_ram_sel  <= '1' when cpu_addr(15 downto 10) = "100001" else '0';              -- $8400-$87FF
    color_ram_sel  <= '1' when cpu_addr(15 downto 10) = "100010" else '0';              -- $8800-$8BFF
    sprite_ram_sel <= '1' when cpu_addr(15 downto 10) = "100011" else '0';              -- $8C00-$8FFF
    io_sel         <= '1' when cpu_addr(15 downto 12) = "1001" else '0';                -- $9000-$93FF

    -- ROM connections
    rom_ce   <= rom_sel or bank_sel;
    rom_addr <= cpu_addr;

    -- RAM write logic
    ram_ce   <= ram_sel or video_ram_sel or color_ram_sel or sprite_ram_sel;
    ram_addr <= cpu_addr(10 downto 0);  -- Up to 2KB addressable
    ram_we   <= not cpu_rw;
    ram_data_out <= cpu_data_out;

    -- Default placeholders for audio/coprocessor
    z80_irq <= '0';
    z80_nmi <= '0';

end Behavioral;
