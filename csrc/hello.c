#include <stdio.h>
#include <string.h>
int main(void) {
  const char *msg = "hello from wasm in cobalt";
  // exercise some libc + arithmetic so the module isn't trivial
  long sum = 0;
  for (int i = 1; i <= 100; i++) sum += i;
  printf("%s; sum(1..100)=%ld; len=%zu\n", msg, sum, strlen(msg));
  return 0;
}
