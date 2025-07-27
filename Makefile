CC := gcc
CC_FLAGS := -Og -g --std=c23 -D_POSIX_C_SOURCE=199309L # debug optimizations, debug symbols

all: ./bin/get

./bin/value: value.c
	mkdir -p bin
	${CC} ${CC_FLAGS} $^ -o ./bin/value


.PHONY: dim
dim: bin/value
	./bin/value -b "/dev/i2c-3" 0
	./bin/value -b "/dev/i2c-4" 0

.PHONY: bright
bright: value
	./bin/value -b "/dev/i2c-3" 100
	./bin/value -b "/dev/i2c-4" 100

./bin/get: get.c
	mkdir -p bin
	${CC} ${CC_FLAGS} $^ -o ./bin/get

.PHONY: clean
clean:
	rm -rf ./bin/
