// TODO: The only way I can see this being better for my use case is:
// 1. Pass multiple buses to one command (maybe even with different brightness values)
// 2. Might be nice to add a function which gets the current brightness?
  // this would allow me to increment the current brightness by `n`

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <stdbool.h>

int main(int argc, char *argv[]) {
  int opt;
  char *bus;
  while ((opt = getopt(argc, argv, "b:")) != -1) {
    switch (opt) {
      case 'b': 
	bus = optarg;
	break;
      default: 
	return 1; 
	break;
    }
  }
  if (optind != argc-1) {
    printf("Usage: ./a.out -b '/dev/<device>' <brightness>\n");
    return 1;
  }
  char *bn = argv[optind];
  int brightness = atoi(bn);

  int i2c3 = open(bus, O_RDWR);
  if (i2c3 == -1) {
    printf("Failed to open %s\n", bus);
    return 1;
  } 
  int addr = 0x37;
  int driver = ioctl(i2c3, I2C_SLAVE, addr);
  if (driver == -1) {
    printf("Failed to open %s on %d address", bus, addr);
    return 1;
  }

  unsigned char msg[7] = {0x51, 0x84, 0x03, 0x10, 0x00, brightness, 0xa4};
  int bytes_written = write(i2c3, msg, sizeof(msg));
  if (bytes_written == -1) {
    printf("Failed to write to %s\n", bus);
    return 1;
  } else {
    printf("Successfully changed the brightness of %s to %d\n", bus, brightness);
    return 0;
  }
}
