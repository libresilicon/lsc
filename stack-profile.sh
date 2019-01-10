#!/bin/sh

# stack build --executable-profiling --library-profiling --ghc-options="-fprof-auto -rtsopts" && stack exec -- lsc +RTS -p

# stack build --profile --ghc-options=-fprof-auto && stack exec -- lsc-test +RTS -p

# stack build --profile --ghc-options=-fprof-auto && stack exec -- lsc -J -u ../rocket-chip-verilog/freechips.rocketchip.system.DefaultConfig.v +RTS -p

# stack build --profile --ghc-options=-fprof-auto && stack exec -- lsc -J -x -l tests/osu035.lef -b ../rocket-chip-verilog/rocket.blif +RTS -p -N6

# stack build --profile --ghc-options=-fprof-auto && stack exec -- lsc -l tests/osu035.lef -b tests/picorv32.blif -c svg -d -j 2 +RTS -p -N2 > result1.svg

stack build --profile --ghc-options=-fprof-auto && stack exec -- lsc -l tests/osu035.lef -b tests/fulladder.blif -c svg -d -j 2 +RTS -p -N2 > result1.svg

# stack build --profile --ghc-options=-fprof-auto-top && stack exec -- lsc-test +RTS -p
