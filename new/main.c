#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/i2c-dev.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  int opt;
  char *bus;
  bool increase;
  bool get = false;
  bool flag = false;
  int option_index = 0;
  static struct option long_options[] = {{"bus", required_argument, 0, 0}};
  while ((opt = getopt_long(argc, argv, "idg", long_options, &option_index)) !=
         -1) {
    switch (opt) {
    case 0:
      bus = optarg;
      break;
    case '0':
    case 'i':
      increase = true;
      flag = true;
      break;
    case 'd':
      increase = false;
      flag = true;
      break;
    case 'g':
      get = true;
      break;
    default:
      return 1;
      break;
    }
  }
  if (!get && (optind != argc - 1 || !flag)) {
    printf("Example usage: ./a.out --bus '/dev/<device>' -i <brightness>\n");
    return 1;
  }
  char *bn = "0";
  int brightness = 0;
  if (!get) {
    bn = argv[optind];
    brightness = atoi(bn);
  }

  int i2c = open(bus, O_RDWR);
  if (i2c == -1) {
    fprintf(stderr, "Failed to open %s: %s\n", bus, strerror(errno));
    return 1;
  }

  int lock = flock(i2c, LOCK_EX);
  if (lock == -1) {
    perror("Failed to lock");
  }

  int addr = 0x37;
  int driver = ioctl(i2c, I2C_SLAVE, addr);
  if (driver == -1) {
    fprintf(stderr, "Failed to open %s on %d address: %s\n", bus, addr,
            strerror(errno));
    return 1;
  }

  unsigned char get_vcp_feature[6] = {0x51, 0x82, 0x01, 0x10,
                                      (0x51 ^ 0x82 ^ 0x01 ^ 0x10)};

  ssize_t bytes_written = write(
      i2c, get_vcp_feature, sizeof(get_vcp_feature) / sizeof(unsigned char));

  if (bytes_written == -1) {
    fprintf(stderr, "Failed to write to %s: %s\n", bus, strerror(errno));
    return 1;
  }

  usleep(40000);

  unsigned char vcp_feature_reply[15] = {0};
  ssize_t bytes_read = read(i2c, vcp_feature_reply,
                            sizeof(vcp_feature_reply) / sizeof(unsigned char));
  if (bytes_read == -1) {
    fprintf(stderr, "Failed to read from %s: %s\n", bus, strerror(errno));
    return 1;
  }

  unsigned char current_brightness = vcp_feature_reply[9];

  if (get) {
    printf("{\"percentage\": %d}", current_brightness);
  } else {
    int new_brightness;
    if (increase) {
      new_brightness = current_brightness + brightness;
      if (new_brightness > 100) {
        new_brightness = 100;
      }
    } else {
      new_brightness = current_brightness - brightness;
      if (new_brightness < 0) {
        new_brightness = 0;
      }
    }

    unsigned char set_vcp_feature[7] = {
        0x51,
        0x84,
        0x03,
        0x10,
        0x00,
        new_brightness,
        (0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ new_brightness)};

    bytes_written = write(i2c, set_vcp_feature, sizeof(set_vcp_feature));

    usleep(50000);
  }

  int unlock = flock(i2c, LOCK_UN);
  if (unlock == -1) {
    perror("unlock");
  }
}
