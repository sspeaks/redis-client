# redis-client

cabal run redis-client --enable-profiling -- +RTS -hT -pj -RTS -h localhost -d 1 -f
cabal run redis-client --enable-profiling --profiling-detail=late -- +RTS -hT -pj -RTS -h localhost -d 1 -f 

hp2ps
evince
https://www.speedscope.app/

https://stackoverflow.com/questions/61666819/haskell-how-to-detect-lazy-memory-leaks

https://stackoverflow.com/questions/3276240/tools-for-analyzing-performance-of-a-haskell-program