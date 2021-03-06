Time-warp: Library for emulating distributed systems.
---

[![Build Status](https://travis-ci.org/serokell/time-warp.svg?branch=master)](https://travis-ci.org/serokell/time-warp)

Time-warp consists of 2 parts:
  1. `MonadTimed` library, which provides time (ala `threadDelay`) and
     threads (ala `forkIO`, `throwTo` and others) management capabilities.
  2. `MonadTransfer` & `MonadDialog`, which provide robust network layer,
     allowing nodes to exchange messages utilizing user-defined serialization
     strategy.  

All these allow to write scenarios over distributed systems, which could be
launched either as real program or as fast emulation with manually controlled
network nastiness.
