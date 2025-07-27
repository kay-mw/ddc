#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <stdbool.h>
#include <time.h>
#include <stdint.h>

int main(int argc, char *argv[]) {
  int opt;
  // char *bus;
	//  while ((opt = getopt(argc, argv, "b:")) != -1) {
	//    switch (opt) {
	//      case 'b': 
	// bus = optarg;
	// break;
	//      default: 
	// return 1; 
	// break;
	//    }
	//  }
	//  if (optind != argc-1) {
	//    printf("Usage: ./a.out -b '/dev/<device>' <brightness>\n");
	//    return 1;
	//  }
	//  char *bn = argv[optind];
	//  int brightness = atoi(bn);
	//
  char *bus = "/dev/i2c-3";
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
  
  unsigned char msg[6] = {0x51, 0x82, 0x01, 0x10, (0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10)};

  

  int bytes_written = write(i2c3, msg, sizeof(msg) / sizeof(unsigned char));

  if (bytes_written == -1) {
    perror("Gay");
  }
  
  struct timespec forty_ms = {.tv_nsec = 40'000'000};
  nanosleep(&forty_ms, nullptr);
  
  unsigned char reply[15] = {0};
  ssize_t bytes_read = read(i2c3, reply, sizeof(reply) / sizeof(unsigned char));
  if (bytes_read == -1) {
    perror("Straight");
  }


  uint8_t max_value_low = reply[7];

  unsigned char present_value_high = reply[8];
  unsigned char present_value_low = reply[9];

  int16_t value = 0;
  value |= (present_value_high << 8);
  value |= (present_value_low);

  printf("Maximum value: %d\n", max_value_low);
  printf("Current value: %d\n", present_value_low);
}
