-------------------------------------------------------------------------------
-- Title      : hwla_pkg
-- Project    : Asylum
-------------------------------------------------------------------------------
-- File       : hwla_pkg.vhd
-- Author     : Mathieu Rosiere
-------------------------------------------------------------------------------
-- Description: HWLA (Hardware Logic Analyzer) functions and components
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author   Description
-- 2026-10-22  1.0      mrosiere Created
-------------------------------------------------------------------------------

library IEEE;
use     IEEE.STD_LOGIC_1164.ALL;
use     IEEE.NUMERIC_STD.ALL;
library asylum;
use     asylum.math_pkg.all;

package hwla_pkg is

  -----------------------------------------------------------------------------
  -- hwla_tdata_width
  -----------------------------------------------------------------------------
  -- Width of the AXI-Stream tdata for nb_probe probes : nb_probe rounded up
  -- to an integer number of bytes (AXI4-Stream), the unused MSB are 0
  function hwla_tdata_width (nb_probe : positive) return positive;

-- [COMPONENT_INSERT][BEGIN]
component hwla_ram is
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
end component hwla_ram;

-- [COMPONENT_INSERT][END]

end hwla_pkg;

package body hwla_pkg is

  -----------------------------------------------------------------------------
  -- hwla_tdata_width
  -----------------------------------------------------------------------------
  function hwla_tdata_width (nb_probe : positive) return positive is
  begin
    return 8*((nb_probe+7)/8);
  end function;

end package body hwla_pkg;
