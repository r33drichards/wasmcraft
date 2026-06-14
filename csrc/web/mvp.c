// mvp.c — Stage 0 proof of the pipeline: NO HTML/CSS/JS yet, just a hand-built
// "page" emitted through the draw protocol (draw.h). This exists only to verify
// the wasm -> browser.lua -> CC monitor loop end to end with the least possible
// code. Later stages replace this main() with a real HTML/CSS layout engine
// (and then QuickJS) that emits the very same protocol.
#include "draw.h"

int main(void) {
  const int W = 30, H = 9;
  draw_size(W, H);
  draw_clear(COL_WHITE);

  // a title bar across the top
  draw_rect(0, 0, W, 1, COL_BLUE);
  draw_text(1, 0, COL_WHITE, COL_BLUE, "wasmcraft web - stage 0");

  // body copy
  draw_text(1, 2, COL_BLACK, COL_WHITE, "Hello from wasm!");
  draw_text(1, 3, COL_GRAY, COL_WHITE, "Rendered on a CC monitor");
  draw_text(1, 4, COL_GRAY, COL_WHITE, "via the draw protocol.");

  // colour swatches prove the 16-colour palette mapping survives the round trip
  draw_rect(1, 6, 4, 2, COL_RED);
  draw_rect(6, 6, 4, 2, COL_LIME);
  draw_rect(11, 6, 4, 2, COL_YELLOW);
  draw_rect(16, 6, 4, 2, COL_CYAN);

  draw_frame_end();
  return 0;
}
