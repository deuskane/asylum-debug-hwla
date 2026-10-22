-------------------------------------------------------------------------------
-- Title      : hwla_ram
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_ram.vhd
-- Author     : Mathieu Rosiere
-- Company    :
-- Created    : 2026-10-22
-- Last update: 2026-10-22
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Simple dual port RAM of the HWLA, one clock per port :
-- * Write port : clocked by wclk_i (trigger domain), the word wdata_i is
--                written at the address waddr_i when we_i = 1
-- * Read port  : clocked by rclk_i (extraction domain), synchronous read :
--                rdata_o is the word at the address raddr_i one clock cycle
--                after re_i = 1, and is held while re_i = 0
-- No reset, no read during write protection : the user of the RAM never
-- reads a word while it is written (the HWLA does not record samples during
-- an extraction). Inferred as a block RAM with two clocks.
-------------------------------------------------------------------------------
-- Copyright (c) 2026
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-------------------------------------------------------------------------------

library IEEE;
use     IEEE.STD_LOGIC_1164.ALL;
use     IEEE.NUMERIC_STD.ALL;

library asylum;
use     asylum.math_pkg.ALL;

entity hwla_ram is
  generic (
    WIDTH        : positive := 8;                                  -- Width of a word
    DEPTH        : positive := 256                                 -- Number of words (power of 2)
    );
  port (
    -- Write port (wclk_i domain)
    wclk_i       : in  std_logic;
    we_i         : in  std_logic;                                  -- 1 : write wdata_i at waddr_i
    waddr_i      : in  std_logic_vector(log2(DEPTH)-1 downto 0);
    wdata_i      : in  std_logic_vector(WIDTH      -1 downto 0);

    -- Read port (rclk_i domain)
    rclk_i       : in  std_logic;
    re_i         : in  std_logic;                                  -- 1 : read the word at raddr_i
    raddr_i      : in  std_logic_vector(log2(DEPTH)-1 downto 0);
    rdata_o      : out std_logic_vector(WIDTH      -1 downto 0)    -- Word read, held while re_i = 0
    );
end entity hwla_ram;

architecture rtl of hwla_ram is

  type     ram_t is array (0 to DEPTH-1) of std_logic_vector(WIDTH-1 downto 0);

  signal   ram_r                  : ram_t;
  signal   rdata_r                : std_logic_vector(WIDTH-1 downto 0);

begin  -- architecture rtl

  -----------------------------------------------------------------------------
  -- Write port
  -----------------------------------------------------------------------------
  process(wclk_i)
  begin
    if rising_edge(wclk_i)
    then
      if we_i = '1'
      then
        ram_r(to_integer(unsigned(waddr_i))) <= wdata_i;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Read port
  -----------------------------------------------------------------------------
  -- Output register : loaded on a read, held otherwise
  process(rclk_i)
  begin
    if rising_edge(rclk_i)
    then
      if re_i = '1'
      then
        rdata_r <= ram_r(to_integer(unsigned(raddr_i)));
      end if;
    end if;
  end process;

  rdata_o              <= rdata_r;

-- pragma translate_off
  -- The address width is log2(DEPTH) (floor) : with a DEPTH that is not a
  -- power of 2, the words 2**log2(DEPTH) to DEPTH-1 can not be addressed
  assert DEPTH >= 2 and is_pow2(DEPTH)
    report "hwla_ram : DEPTH (" & integer'image(DEPTH) & ") must be a power of 2, at least 2"
    severity failure;
-- pragma translate_on

end architecture rtl;
