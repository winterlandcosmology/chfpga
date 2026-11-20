.. title:: RAWPACK

**************************************************************
:entity:`RAWPACK` (*rawpack.vhd*): Raw ADC sample streamer
**************************************************************

.. default-role:: vhdl:entity

Overview
========

`rawpack` streams raw ADC samples of one or two channels over the 100G Ethernet link as UDP
packets. It sends 12 bits for each sample: the 12 most significant bits of the 14-bit ADC sample.
Each packet holds the samples of one channel. With two channels there are two packet streams, A
and B, one for each channel. A receiver gets contiguous samples of a channel from each packet, and
separates the streams with the UDP destination port or with the stream bit of the header.

It sits between `upack` and `cge`:

- When disabled (reset state), the `upack` stream passes through with one clock of latency.
- When enabled, the link carries the raw stream instead. The two uses are mutually
  exclusive: stop the `upack` transmitter before enabling `rawpack`. When `rawpack` is disabled
  again, the packets in progress are completed before the link is handed back.

The samples are taken from the capture bus that feeds `ucap` (8 samples per clock per channel),
so no extra logic is added to the channelizers. The data source of each channel (FUNCGEN output,
i.e. ADC samples or a test pattern, or SCALER output) is the one selected in `ucap`; `rawpack`
reports it in the packet header.

Data rates at 3.2 GS/s:

=============  ================  ==============================  ==================
Mode           Sample data rate  Packets (64 blocks per packet)  Samples per packet
=============  ================  ==============================  ==================
Two channels   76.8 Gb/s         2 x 0.78125 million per second  4096 of one channel
One channel    38.4 Gb/s         0.78125 million per second      4096
=============  ================  ==============================  ==================

For each channel, two consecutive input words make a 192-bit word, and a 3:4 gearbox packs these
into 256-bit words. Each channel has a block RAM FIFO (512 words) that holds its packets until
they are sent. A packet is sent when it is complete in its FIFO, and the streams take turns: a
packet of A, then the packet of B that covers the same time.

Entity documentation
====================

.. parse:: hdl/data_links/100GE_UDP_MAC/rawpack.vhd

.. autoentity:: rawpack

Packet format
=============

All multi-byte header fields are big-endian. With the default 64 blocks per packet the Ethernet
frame is 6208 bytes long (without FCS), so the network path needs a jumbo MTU (9000).

===========  ==========================================================================
Bytes        Content
===========  ==========================================================================
0-13         Ethernet header: destination MAC, source MAC, ethertype 0x0800
14-33        IPv4 header: no options, DF set, TTL 64, protocol UDP, valid header checksum
34-41        UDP header. The checksum is 0 (not used). The destination port is
             ``port_dest`` for stream A and ``port_dest`` + 1 for stream B (the same port
             if ``port_per_channel`` = 0).
42-43        Magic number 0x5241 ("RA")
44           Format version (3)
45           Flags: bit 0 = data source of the channel of this packet,
             bit 2 = single-channel mode, bit 7 = internal FIFO overflow (sticky)
46           Bits 2:0 = channel number of the samples of this packet. Bit 7 = stream:
             0 = stream A, 1 = stream B.
47           Blocks per packet
48-53        Packet counter of this stream (48 bits). Zero on the first packet of each
             start from the stopped state, and after a reset.
54-59        Frame number (48 bits) of the first sample; same counter as the `ucap` timestamp
60-61        Word number (0-2047) of the first sample in its frame. The first sample of the
             packet is sample 8 x word of that frame.
62           Stream number: incremented every time the streams start, including a restart
             after a reset. The packet counters restart at zero at the same time.
63           Reserved (0)
64...        Samples: 96 bytes per block
===========  ==========================================================================

The sample area is a little-endian bit stream: stream bit *n* is bit (*n* mod 8) of byte
(*n* / 8). Sample *i* of the packet occupies stream bits 12 *i* to 12 *i* + 11, least
significant bit first, so every 2 samples fill exactly 3 bytes. A sample value is the 14-bit ADC
sample divided by 4 (signed, -2048 to 2047). The samples of a packet are in time order and belong
to one channel. A block is 64 samples. The first packets after the stream is enabled start on the
first sample of a frame; with 64 blocks per packet a frame is exactly 4 packets of each stream.
The packets of A and B with the same packet counter cover the same time: the two counters
restart at zero each time the streams start from the stopped state, so a run in single-channel
mode (which sends stream A only) does not put them out of step.

A receiver detects lost packets with the packet counter of each stream and places the samples in
time with the frame and word numbers.

Parameters
==========

- **DEFAULT_ENABLE / DEFAULT_SINGLE / DEFAULT_CHAN_A / DEFAULT_CHAN_B / DEFAULT_BLOCKS_PER_PACKET:**
  reset values of the corresponding registers.

- **DEFAULT_MAC_SRC_ADDR / DEFAULT_MAC_DEST_ADDR / DEFAULT_IP_SRC_ADDR / DEFAULT_IP_DEST_ADDR /
  DEFAULT_IP_SRC_PORT / DEFAULT_IP_DEST_PORT:** reset values of the addresses used in the packet
  headers. All can be changed at run time.

Registers
=========

`rawpack` is at port 6 of the top-level BSB router. The memory map is in the entity source
(control bytes 0-27, status bytes 0-14). Notes:

- ``blocks_per_packet`` (4 to 90), ``single`` and ``port_per_channel`` are taken into account only while the stream is completely stopped (status bit ``raw_active`` = 0). Host software should disable the stream and wait for ``raw_active`` to clear before changing them.
- ``src_port_mask`` adds the low bits of the packet counter to the UDP source port, so that the
  receiving network card spreads the packets over several receive queues. The receiver then has
  to put the packets back in order using the packet counter.

Simulation
==========

See :doc:`the testbench list </testbenches/index>`: ``rawpack_testbench`` (self-checking unit
test) and ``rawpack_cge_testbench`` (full-rate chain with `cge` and a behavioural model of the
100G MAC). Both are run with the scripts in ``xilinx_projects/testbenches/rawpack_testbench/``.
