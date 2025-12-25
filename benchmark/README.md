To run benchmarks first run:
```
./init.sh
```
Reference benchmark:
```
cd qoi-reference
make
./qoibench 10 ../qoi-benchmark-suite --nopng --onlytotals
```
Zig benchmark:
```
cd zqoi
zig build -Doptimize=ReleaseFast
./zig-out/bin/zqoi-bench ../qoi-benchmark-suite
```
