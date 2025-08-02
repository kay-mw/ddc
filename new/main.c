#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

int get(int i2c, int addr) {
  char *bus = "/dev/i2c-3";

  unsigned char get_vcp_feature[6] = {0x51, 0x82, 0x01, 0x10,
                                      (0x51 ^ 0x82 ^ 0x01 ^ 0x10)};

  ssize_t bytes_written = write(i2c, get_vcp_feature, sizeof(get_vcp_feature));
  if (bytes_written == -1) {
    fprintf(stderr, "Failed to write to %s: %s\n", bus, strerror(errno));
    return 1;
  }

  usleep(10000);
  unsigned char vcp_feature_reply[15] = {0};
  ssize_t bytes_read = read(i2c, vcp_feature_reply, sizeof(vcp_feature_reply));
  if (bytes_read == -1) {
    fprintf(stderr, "Failed to read from %s: %s\n", bus, strerror(errno));
    return 1;
  }

  int current_brightness = vcp_feature_reply[9];

  printf("{\"brightness\": %d}", current_brightness);

  return current_brightness;
}

int set(int i2c, int current_brightness, int brightness, bool increase) {
  char *bus[2] = {"/dev/i2c-3", "/dev/i2c-4"};

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

  int bytes_written = write(i2c, set_vcp_feature, sizeof(set_vcp_feature));

  usleep(5000);

  if (bytes_written == -1) {
    fprintf(stderr, "Failed to read bus: %s\n", strerror(errno));
    return 1;
  }

  return 0;
}

int main(int argc, char *argv[]) {
  int opt;
  bool increase;
  bool flag = false;
  while ((opt = getopt(argc, argv, "id")) != -1) {
    switch (opt) {
    case 'i':
      increase = true;
      flag = true;
      break;
    case 'd':
      increase = false;
      flag = true;
      break;
    default:
      return 1;
      break;
    }
  }
  if (optind != argc - 1 || !flag) {
    printf("Example usage: ./a.out --bus '/dev/<device>' -i <brightness>\n");
    return 1;
  }
  char *bn = argv[optind];
  int brightness = atoi(bn);

  char *bus = "/dev/i2c-3";

  int i2c = open(bus, O_RDWR);
  if (i2c == -1) {
    fprintf(stderr, "Failed to open %s: %s\n", bus, strerror(errno));
    return 1;
  }

  int lock = flock(i2c, LOCK_EX);
  if (lock == -1) {
    fprintf(stderr, "Failed to lock %d: %s\n", i2c, strerror(errno));
  }

  int addr = 0x37;
  int driver = ioctl(i2c, I2C_SLAVE, addr);
  if (driver == -1) {
    fprintf(stderr, "Failed to open %s on %d address: %s\n", bus, addr,
            strerror(errno));
    return 1;
  }

  int current_brightness = get(i2c, addr);
  if (brightness != 0) {
    set(i2c, current_brightness, brightness, increase);
  }
  int unlock = flock(i2c, LOCK_UN);
  if (unlock == -1) {
    fprintf(stderr, "Failed to unlock %d: %s\n", i2c, strerror(errno));
  }

  return 0;
}
