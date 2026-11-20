.. title:: 100G Ethernet UDP/MAC

100G Ethernet UDP/MAC
*********************

.. default-role:: vhdl:entity

The 100G Ethernet UDP/MAC modules implement high-speed Ethernet communication using 100 Gbps links on Ultrascale+ FPGAs. These modules provide data transmission for corner-turn operations and other high-bandwidth applications.

The 100G Ethernet system consists of:

- :entity:`cge`: 100G Ethernet core module that implements the CMAC (100G Ethernet Media Access Control) interface, providing packet transmission and reception capabilities with memory-mapped configuration and monitoring
- :entity:`rawpack`: Raw ADC sample streamer. Sends the 14-bit samples of one or two channels over the 100G link instead of the corner-turned data

.. toctree::
   :maxdepth: 2
   :hidden:

   cge
   rawpack
