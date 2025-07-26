CC := gcc
CC_FLAGS := -Og -g # debug optimizations, debug symbols



bin/value: value.c
	mkdir -p bin
	${CC} ${CC_FLAGS} $^ -o bin/value


.PHONY: dim
dim: bin/value
	./bin/value -b "/dev/i2c-3" 0
	./bin/value -b "/dev/i2c-4" 0

.PHONY: bright
bright: value
	./bin/value -b "/dev/i2c-3" 100
	./bin/value -b "/dev/i2c-4" 100

.PHONY: clean
clean:
	tp -r value
