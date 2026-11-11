// Origin: errno.c from Bruno Levy's learn-fpga, FROM_BLINKER_TO_RISCV/FIRMWARE
// (BSD-3-Clause; see LICENSE).
//
// A stand-in for newlib's __errno, which libm calls (tinyraytracer's powf()
// does) but this firmware does not link. __errno returns a pointer to the
// error variable, not the variable itself (for multithreading).

int* __errno()  {
   static int val = 0;
   return &val;
}
