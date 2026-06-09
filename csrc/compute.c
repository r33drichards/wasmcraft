#include <stdio.h>
#include <stdlib.h>
static int cmp(const void *a, const void *b) { return *(const int*)a - *(const int*)b; }
int main(void) {
  int n = 50;
  int *v = malloc(n * sizeof(int));
  unsigned s = 12345;
  for (int i = 0; i < n; i++) { s = s * 1103515245u + 12345u; v[i] = (s >> 16) % 1000; }
  qsort(v, n, sizeof(int), cmp);
  long total = 0; for (int i = 0; i < n; i++) total += v[i];
  printf("min=%d max=%d sum=%ld median=%d\n", v[0], v[n-1], total, v[n/2]);
  free(v);
  return 0;
}
