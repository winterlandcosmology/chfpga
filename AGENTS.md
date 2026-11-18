# Agent notes — chfpgalite

Standing instructions and durable knowledge for AI agents working in this
repository. Maintained at the user's request; keep this file curated and
concise.

## Ground rules

- **Never create git commits unless explicitly asked.** Implement changes in
  the working tree and report; the user decides when to commit. When asked,
  use atomic commits with descriptive messages in the `type (scope): summary`
  style; bug fixes go in separate commits explaining both cause and solution.
- Store durable repo knowledge in this file, not in custom side files.
- The user compiles bitstreams themselves; prepare sources and verify, then
  hand off.
- The repo lives at git@github.com:winterlandcosmology/chfpga.git (moved from
  bitbucket.org/winterlandcosmology/chfpgalite in Nov 2026). The move rewrote
  history (only `hooks/README` dropped), so most commit hashes changed;
  hashes quoted from before the move may be stale — look the commit up by
  subject.

## Build environment

- Vivado 2022.2: `source /tools/Xilinx/Vivado/2022.2/settings64.sh` (user
  alias: `act_vivado_2022`). The environment does not persist between shell
  invocations — source it in every command that needs Vivado tools.
- Projects are script-generated (`tcl/project_sources.tcl` +
  `create_project.tcl`); never GUI-edit `.xpr` files. `make <config>
  project|bitstream|clean`.
- Style: `cd hdl && vsg -c vsg_rules.yaml -f <files>` (vsg at
  /usr/local/bin/vsg). Beware `vsg --fix`: it mass-reformats legacy files far
  beyond whitespace — do not mix that churn into functional commits.
- `xvhdl` aborts the whole invocation at the first failing file, and units
  depending on ungenerated Xilinx IP cannot be analyzed outside the project —
  "not compiled in library" cascades there are expected, not code errors.
- Vivado cannot pass VHDL enum generics via the project `generic` property
  (values get ASCII-encoded), so testbench projects needing enum generics are
  sim-only.

## Corner turn / ct_prober

- The ct_prober capture probe (cookie 0xA2, BSB port 6) captures whole CT
  packets verbatim (TLAST-delimited, size-agnostic), so it sees the flags
  blocks whenever the corner turn is configured with send_flags. shuffle16
  packet sizes: 517/1029 words (1/2 frames per packet, flags off) and
  582/1159 words (flags on) — all fit the 2048-word capture FIFO
  (3/1/3/1 packets per burst respectively). The header comment table in
  ct_prober.vhd previously claimed 597/1221 and that flags-on fpp=2 does
  not fit; those numbers were wrong and are corrected in the working tree.
  The pychfpga ct_prober test suite uses flags-off fpp=1 as its canonical
  algorithm-test operating point and reconfigures to flags-on for the
  flags tests.
- Known defect, characterized but deliberately NOT fixed (needs a TUSER
  repack + recompile): the CT packet's per-bin data-flags words do not
  carry scaler overflow flags. chan.vhd:695 truncates the scaler's 5-bit
  TUSER to 3:0 (dropping the high-bin scaler overflow), and chan_bin_sel
  samples stale constants (chfpga_package.vhd:534-540: SCALER_LOW collides
  with FFT_OVERFLOW=1, SCALER_HIGH with GAINBANK=2), so it reads the
  gain-bank and FFT-overflow bits instead — both asserted only at frame
  end, leaving the data-flags block ~all-zero. Confirmed on silicon under
  maximal flag forcing: only lane 7's final flags word goes nonzero
  (0xFFFF, the FFT-overflow flag on the frame's TLAST word); lane 6's
  gain-bank read stays 0 for the default bank. The per-frame frame-flags
  word (ADC + FFT overflow per channel) is correctly wired and verified
  bit-exactly by pychfpga's ct_prober_test.py flags tests.
- Known defect #2 (reconnected GPU path, found on the bench, NOT yet
  fixed): a GPU core reset (GPU.RESET pulse) released while the
  corner-turn stream is running intermittently (~1 attempt in 3) leaves
  one lane's 10G TX FIFO permanently wedged - the MAC accepts s_axis
  words the moment the fabric reset deasserts while the FIFO/GTX are
  still completing reset; the dropped words desynchronize the header and
  data FIFOs and both overflow continuously (stickies re-assert within
  100 ms of every OVERFLOW_RESET) until the next core reset. Candidate
  RTL fix: hold the axis_gpu tvalid gate until TX resetdone AND the FIFO
  wr_rst_busy are clear, and re-enable only at a packet (TLAST) boundary.
  Software workaround until then: retry the core reset until the overflow
  flags stay quiet (see _gpu_clean_start in pychfpga's ct_prober_test.py).
  Not rate- or packet-size-dependent (flags-on fpp=1 and fpp=2 behave
  identically; TEST_ENABLE off).
- Two unrelated QSFP domains on ICE, routinely confused. (a) The two
  *motherboard* QSFP+ cages carry the X-engine offload: 8 TX-only 10GBASE-R
  links at 10.3125 Gbd (322.27 MHz word clock, xge_array LINK_SPEED=1),
  xge lanes 0-3 = cage A on GTX quad 116, 4-7 = cage B on quad 117, both fed
  by the single 156.25 MHz MGTREFCLK0_116 (pin F6). (b) The *backplane* QSFP
  carries the crate-to-crate corner-turn shuffle: only 4 links per board, on
  GTX quad 113 (CT links 15-18, CT lanes 20-23), at 7.8125 Gbd/244.14 MHz
  (BP_LINK_SPEED=0) like the 15 backplane PCB links - this is the clock that
  becomes ct_clk. Those 4 links are used only in shuffle512; shuffle256
  bypasses them (CT lanes 16-19 are the bypass path straight from CB2 to
  CB3). So "2 QSFP ports" and "4 QSFP links" refer to different connectors.
- GPU 10G link wire format (ice_ct): 8 TX-only lanes out the two
  motherboard QSFP+ cages (lanes 0-3 on GTX quad 116, 4-7 on 117),
  standard 10GBASE-R — 10.3125 Gbd, 64b/66b with the standard scrambler,
  156.25 MHz refclk, no autoneg, no FEC, no flow control. xge_udp_mac_tx
  emits real Ethernet/IPv4/UDP frames (FCS appended, no ARP, no minimum-
  frame padding, UDP checksum 0 = legal "none", UDP source port 0).
  ice_ct compiles xge_array's defaults (chfpga.vhd generic map is
  commented out): src MAC 12:34:56:78:9A:BC, dst MAC ff:ff:ff:ff:ff:ff
  (broadcast), 10.10.10.11 → 10.10.10.10, UDP dst port 41000. Setting
  DEST_ADDR_MODE=1 repurposes registers per lane i: dst IP =
  TEST_PACKET_LENGTH<<16 | i, dst port = TEST_PACKET_PERIOD, dst MAC =
  0000:(TEST_PACKET_LENGTH):00:(i). Receivers need fixed-10G ports
  (autoneg/FEC off) and MTU ≥ ~4.8 KB (shuffle256 flags-on fpp=2 is a
  4756-byte UDP payload); TEST_ENABLE sends test packets without the
  corner turn running. A QSFP28 NIC (e.g. E810-C) must be in a 10G
  breakout port option (devlink port split / epct); a passive QSFP+/28
  DAC cage-to-cage carries 4 lanes.
- BSB address hierarchy: top router bits 18:16, bct_engine router bits 15:14,
  crossbar routers bits 13:9 (5-bit port index, 9-bit space per port,
  matching pychfpga's `port << 9`). The crossbar ADDRESS_MASKs were fixed to
  this layout in 22d993e8 — keep any new sub-router consistent with it.
- Several corner-turn status registers are declared but never driven in the
  RTL and always read zero: chan_crossbar's INPUT_FRAME_CTR/ALIGN_FRAME_CTR
  and lane monitor. Do not use them as dataflow indicators; the live
  counters are chan_bin_sel.IN_FRAME_CTR and the shuffle_crossbar
  INPUT/ALIGN/OUTPUT_FRAME_CTRs. The GPU link's FRAME_CTR counts frames
  entering the 10G MAC TX path: dead on bitstreams predating the aug11
  ct_out reconnection, live since. CROSSBAR3.OUTPUT_FRAME_CTR remains the
  canonical corner-turn dataflow indicator (works with or without GPU
  links).
- Bring-up ordering matters: release the corner turn (corr_reset) before the
  channelizers (`chFPGA.reset()` does the canonical sequence), then trig and
  sync — otherwise the chan-to-CT stream never starts.
- shuffle256 output packet (per lane k, slot s 1-based, crate c): 4-word
  header with w0 = STREAM_ID16<<16 | 0x14CF, STREAM_ID16 = 0x2000 | c<<8 |
  (s-1)<<4 | k; w1 carries only the send_flags bit reliably — the CB2/CB3
  header-population registers (four_bits, bins, channels) are never written
  by software and read zero. Data: per frame 8 bins x 64 words, each bin =
  256 bytes in ascending global channel order (LSB byte first). Flags: per
  frame 64 data-flags words (word L of a bin covers channels 32L..32L+31)
  and 16 frame-flags words (words 2L/2L+1 = source slots 2L+1/2L+2, each
  {FFT[31:16], ADC[15:0]}). One packet-flags trailer word: bits 0-7 =
  per-CB3-input-lane error, 8 = missing/short frame, 9 = overlong,
  10 = CRC, 11 = FIFO overflow, bits 12+ = CB2's packet flags shifted.
  Totals: 597/1189 words (flags on, 1/2 frames per packet), 517/1029 off.
  The bin at packet position p is absolute bin 16p + (s-1). (Derivation from
  the three selection maps gives 128p + 16k + (s-1) for GPU lane k: CB1 keeps
  bins 16q + (s-1), CB3 lane k keeps positions q = 8p + k. Confirm on a capture
  before relying on either formula.)
- More dead/never-driven status in the shuffle path (verified in RTL):
  shuffle_crossbar's DATA_TIMEOUT_MON (status0 bit7), HAD_TIMEOUT,
  CAPTURE_DONE, TIMEOUT_PERIOD/USE_TIMEOUT controls (unused), and
  xglink_array's rx_frame_ctr (assignment commented out). The live
  lane-absent indicator is MISSING_FRAME (align32's SOF-window check).
  align32 is instantiated without ENABLE_MONITORING_LOGIC, so the
  LANE_MONITOR_SOURCE machinery is inert. LANE_MONITOR_SEL values above 7
  index past the OUTPUT_FRAME_CTR/PACKET_ERROR_CTR arrays.

## Corner turn: aligner, output framing, trailer (Sept 2026 investigation)

- **align32 window semantics** (CROSSBAR2/3), measured with
  `hdl/testbenches/align32_skew_testbench.vhd` (`run_align32_skew.sh`, xsim,
  real SHUFFLE_CROSSBAR_ALIGN_FIFO model): lane 0 (the internal bypass, always
  the fastest lane) opens the window at its header; a lane is accepted iff its
  header reaches its FIFO output within [-(L-1), W+2-L] cycles of lane 0's,
  with L = 3 (FIFO write-to-valid latency), i.e. [-2, +54] for W=55. Late ->
  that packet's lane is dropped (junk in its slot, packet still emitted,
  MISSING_FRAME + BAD_FRAME_LENGTH + BAD_TVALID; BAD_FRAME_LENGTH pulses twice).
  Early by more than 2 -> the lane is dropped on every packet, permanently (a
  flushed lane has nothing queued to hold its next header). Back-to-back
  packets need 1 idle cycle, not 2. FIFO occupancy: 135/512 at W=250 in sim,
  213/512 at W=200 on the crate; align FIFO writes are gated by almost_full
  with no error flag (silent loss if it ever fills). The hardware never
  compares header timestamps: every stage's TIMESTAMP is a local packet counter
  (x frames_per_packet) reset with the module, so cross-board alignment rests
  on the common sync plus window << packet period; verify with the
  FRAME_NUMBER_CAPTURE deltas after every sync.
- **CB2 window is a software value**: RTL default 100 (`DEFAULT_CONTROL_BYTES`
  byte 2), pychfpga forced 55 for years; crate skew survey found 43-56 cycles,
  so the tail dropped ~1% of packets on the slowest board pairs at 55 and zero
  at >= 60. pychfpga now programs 100 (CB3: 110). The same default bytes encode
  ignore_lane = 0x1032 (lanes 1,4,5,12) and a bogus lane map; only pychfpga's
  writes make the module usable.
- **DELAY_CAPTURE protocol**: set LANE_MONITOR_SEL first, then pulse
  LANE_MONITOR_RESET (which also clears the stickies and counters), read after
  > 10 us; value = header skew + 1; SEL=0 returns a different register; a lane
  earlier than lane 0 reads about period + skew. PACKET_ERROR_CTR is 16-bit
  and saturates within a second above ~7% error rate.
- **Per-lane output strobes** (fixed in the working tree, Sept 2026):
  `bct_engine`, `chfpga.vhd` (GPU links, ct_prober, correlator feed) and
  `ct_prober` carry one TVALID/TLAST per lane (vector index = lane number;
  lane 0 at the MSBs of the packed data word). The 2017 design did this
  (7ea1889f); 270a1b6a (2025-07-02) collapsed the engine output to lane 0's
  strobe while the GPU path was disconnected, and 037447ed (2026-08-11) fanned
  that single strobe out to the 10G links. Effect on shuffle128/256/512 (any
  mode with CROSSBAR3 bin selectors active): lane k was sent with k x
  words-per-bin copies of header word 0 in front (8 per lane in shuffle256, 16
  in shuffle512) and lost its last k x words-per-bin words. Bypass modes
  (shuffle16, chord16, chan*, corr*) and level-1 builds were unaffected. The
  stagger itself is by design: bin selector k starts its packet only when its
  first selected bin (position k, spacing 8) is complete.
- **shuffle_bin_sel trailer pollution** (fixed in the working tree): bin
  selectors wrote all sublane data FIFOs but read only first_lane..last_lane;
  in shuffle256 CB2 reads 2 of 4 sublanes per output, the other two FIFOs
  overflowed and their stale heads were OR-ed into the packet-flags word at
  end_of_packet, making the trailer data-dependent (0x4FF with bit 31 set, or
  0x55555000 under the funcgen pattern). CB3 read that bit 31 as a CRC error on
  every lane and its PACKET_ERROR_CTR saturated. `sublane_active`, derived from
  FIRST_LANE/LAST_LANE, now gates the writes and masks the OR; shuffle512 (0,3)
  and CB3 (0,7) are unchanged. pychfpga's `sublane_mask` on FIFO_OVERFLOW is now
  unnecessary.
- **ct_prober arming** (fixed): bursts start only on a packet's first word
  (`sel_tfirst`), removing the 1-in-30 one-word-shifted capture.
- **Flags (trailer) word of an N-input bin_sel**: bits 0..N-1 = per remapped
  input lane any-error; N+0 missing/short (tvalid=0 at the trailer), N+1 too
  long, N+2 "CRC" = bit 31 of the incoming trailer, N+3 FIFO overflow sticky;
  N+4..31 = upstream trailer << (N+4), zeroed for a lane that had an error.
  Masks: CB2 0x00070000, CB3 0x70000700. In the GPU packet bits 12-27 are CB2's
  per-input-lane bits and 28-30 CB2's summary. CB1 (`chan_bin_sel`) writes an
  all-zero trailer and has no missing/bad-lane status registers, so CB1 aligner
  drops are invisible everywhere downstream.
- All 18 legacy corner-turn testbenches reference removed ports
  (`sof_window_start`, `frame_clk_sel`, `CMD_DAT`) and do not compile;
  `align32_skew_testbench` is the only working one.
- Side finding, not acted on: `xglink_array` hard-codes `EXAMPLE_SIMULATION => 1`
  and `SIM => TRUE` into the synthesized `xglink_core`, so the RX startup FSM
  skips the equalizer adaptation wait in hardware.
