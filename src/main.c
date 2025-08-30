#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <unistd.h>

int get(int i2c, int addr, char *bus, int brightness, bool increase) {
  char filename[] = "brightness.txt";
  FILE *fptr;
  fptr = fopen(filename, "r");
  if (fptr != NULL) {
    char data[4];
    if (fgets(data, sizeof(data), fptr) != NULL) {
      int current_brightness = atoi(data);
      fclose(fptr);
      if (brightness == 0) {
        printf("{\"brightness\": %d}\n", current_brightness);
        return current_brightness;
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

        char new_brightness_str[4];
        snprintf(new_brightness_str, sizeof(new_brightness_str), "%d",
                 new_brightness);
        fptr = fopen(filename, "w");
        if (fputs(new_brightness_str, fptr) > 0) {
          fclose(fptr);
        } else {
          fprintf(stderr, "Failed to write to %s: %s\n", filename,
                  strerror(errno));
        }

        return new_brightness;
      }
    } else {
      fprintf(stderr, "Failed to read brightness: %s", strerror(errno));
    }
  }

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
  char file_brightness[4];
  snprintf(file_brightness, sizeof(file_brightness), "%d", current_brightness);

  fptr = fopen(filename, "w");
  if (fputs(file_brightness, fptr) > 0) {
    fclose(fptr);
  } else {
    fprintf(stderr, "Failed to write to %s: %s\n", filename, strerror(errno));
  }

  return current_brightness;
}

int set(int i2c_primary, int i2c_secondary, int current_brightness) {
  unsigned char set_vcp_feature[7] = {
      0x51,
      0x84,
      0x03,
      0x10,
      0x00,
      current_brightness,
      (0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ current_brightness)};

  int bytes_written_primary =
      write(i2c_primary, set_vcp_feature, sizeof(set_vcp_feature));
  if (bytes_written_primary == -1) {
    fprintf(stderr, "Failed to read bus: %s\n", strerror(errno));
    return 1;
  }
  int bytes_written_secondary =
      write(i2c_secondary, set_vcp_feature, sizeof(set_vcp_feature));
  if (bytes_written_secondary == -1) {
    fprintf(stderr, "Failed to read bus: %s\n", strerror(errno));
    return 1;
  }

  usleep(5000);

  return 0;
}

int open_and_lock_i2c(char *bus, int addr) {
  int i2c = open(bus, O_RDWR);
  if (i2c == -1) {
    fprintf(stderr, "Failed to open %s: %s\n", bus, strerror(errno));
    return 1;
  }

  int lock = flock(i2c, LOCK_EX);
  if (lock == -1) {
    fprintf(stderr, "Failed to lock %d: %s\n", i2c, strerror(errno));
  }

  int driver_primary = ioctl(i2c, I2C_SLAVE, addr);
  if (driver_primary == -1) {
    fprintf(stderr, "Failed to open %s on %d address: %s\n", bus, addr,
            strerror(errno));
    return 1;
  }

  return i2c;
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
    printf("Example usage: ./a.out -i/d <brightness>\n");
    return 1;
  }
  char *bn = argv[optind];
  int brightness = atoi(bn);

  char *bus_primary = "/dev/i2c-3";
  char *bus_secondary = "/dev/i2c-4";
  int addr = 0x37;

  int i2c_primary = open_and_lock_i2c(bus_primary, addr);

  int current_brightness =
      get(i2c_primary, addr, bus_primary, brightness, increase);

  if (brightness != 0) {
    int i2c_secondary = open_and_lock_i2c(bus_secondary, addr);

    set(i2c_primary, i2c_secondary, current_brightness);

    int unlock_secondary = flock(i2c_secondary, LOCK_UN);
    if (unlock_secondary == -1) {
      fprintf(stderr, "Failed to unlock %d: %s\n", i2c_secondary,
              strerror(errno));
    }

    int close_secondary = close(i2c_secondary);
    if (close_secondary == -1) {
      fprintf(stderr, "Failed to close %d: %s\n", i2c_secondary,
              strerror(errno));
    }
  }

  int unlock_primary = flock(i2c_primary, LOCK_UN);
  if (unlock_primary == -1) {
    fprintf(stderr, "Failed to unlock %d: %s\n", i2c_primary, strerror(errno));
  }

  int close_primary = close(i2c_primary);
  if (close_primary == -1) {
    fprintf(stderr, "Failed to close %d: %s\n", i2c_primary, strerror(errno));
  }

  return 0;
}
