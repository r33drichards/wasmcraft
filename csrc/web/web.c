// web.c — Stage 1 web engine: parse a subset of HTML + CSS, lay it out into a
// character grid, and emit the draw protocol (draw.h) the Lua host paints onto a
// CC:Tweaked monitor. A WASI "command" module: argv[1] = page file (default
// "index.html") read from the preopened site directory; argv[2] = viewport
// width in cells (default 51). External <link rel=stylesheet> and the page's
// inline <style>/style="" are all honoured.
//
// Deliberately a SUBSET (documented in docs/ and tests). Supported:
//   HTML  html head body div p span h1 h2 h3 a ul li br strong b em i + text
//   CSS   selectors: tag, .class, #id, * (comma lists); properties:
//         display(block|inline|none) color background[-color] text-align
//         font-weight(bold|normal) margin[-top|-bottom] padding[-left] width
//   colours: the 16 CC names + #rgb/#rrggbb mapped to the nearest of 16
// Layout is block + inline flow: blocks stack and fill the content width; inline
// runs wrap at word boundaries; px lengths map to cells at PX_PER_CELL.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>
#include "draw.h"

#define EXPORT(n) __attribute__((export_name(n)))

#define PX_PER_CELL 8           // CSS px -> character cells
#define MAXNODES   4096
#define MAXRULES   512
#define MAXDECLS   8
#define MAXATTRS   8
#define MAXSEL     8
#define MAXLISTENERS 256

// ---- colours ----------------------------------------------------------------
// palette index -> approximate RGB (CC default palette), for nearest-match of
// arbitrary hex colours.
static const int PAL_RGB[16][3] = {
  {240,240,240},{242,178, 51},{229,127,216},{153,178,242}, // white orange magenta lightblue
  {222,222,108},{127,204, 25},{242,178,204},{ 76, 76, 76}, // yellow lime pink gray
  {153,153,153},{ 76,153,178},{178,102,229},{ 51, 51,178}, // lightgray cyan purple blue
  {127,102, 76},{ 87,166, 78},{204, 76, 76},{ 17, 17, 17}, // brown green red black
};
struct NamedColor { const char *name; int idx; };
static const struct NamedColor NAMED[] = {
  {"white",0},{"orange",1},{"magenta",2},{"lightblue",3},{"yellow",4},
  {"lime",5},{"pink",6},{"gray",7},{"grey",7},{"lightgray",8},{"lightgrey",8},
  {"cyan",9},{"purple",10},{"blue",11},{"brown",12},{"green",13},{"red",14},
  {"black",15},
  // a few common web names mapped to the nearest CC slot
  {"silver",8},{"navy",11},{"maroon",14},{"olive",4},{"teal",9},{"fuchsia",2},
  {"aqua",9},{"lime",5},{"darkgray",7},{"darkgrey",7},{0,0}
};

static int nearest_rgb(int r, int g, int b) {
  int best = 15, bestd = 1 << 30;
  for (int i = 0; i < 16; i++) {
    int dr = r - PAL_RGB[i][0], dg = g - PAL_RGB[i][1], db = b - PAL_RGB[i][2];
    int d = dr * dr + dg * dg + db * db;
    if (d < bestd) { bestd = d; best = i; }
  }
  return best;
}
static int hexnib(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  c = tolower((unsigned char)c);
  if (c >= 'a' && c <= 'f') return 10 + c - 'a';
  return -1;
}
// parse a CSS colour token -> palette index, or -1 if unrecognised
static int parse_color(const char *s) {
  while (*s == ' ') s++;
  if (*s == '#') {
    s++;
    int n = (int)strlen(s);
    int r, g, b;
    if (n >= 6) {
      r = hexnib(s[0]) * 16 + hexnib(s[1]);
      g = hexnib(s[2]) * 16 + hexnib(s[3]);
      b = hexnib(s[4]) * 16 + hexnib(s[5]);
    } else if (n >= 3) {
      r = hexnib(s[0]) * 17; g = hexnib(s[1]) * 17; b = hexnib(s[2]) * 17;
    } else return -1;
    if (r < 0 || g < 0 || b < 0) return -1;
    return nearest_rgb(r, g, b);
  }
  char low[32]; int i = 0;
  while (s[i] && i < 31) { low[i] = tolower((unsigned char)s[i]); i++; }
  low[i] = 0;
  for (const struct NamedColor *c = NAMED; c->name; c++)
    if (strcmp(low, c->name) == 0) return c->idx;
  return -1;
}

// ---- DOM --------------------------------------------------------------------
typedef struct { char name[24]; char val[256]; } Attr;
typedef struct {
  int is_elem;                 // 1 element, 0 text
  char tag[16];
  Attr attr[MAXATTRS]; int nattr;
  char *text;                  // text node content (arena)
  int parent, child, sibling;  // node indices, -1 = none
  // computed style (-2 = unset/inherit sentinel where needed)
  int display;                 // 0 block, 1 inline, 2 none
  int color, bg;               // palette idx, -1 = none/inherit
  int bold, align;             // align 0 left, 1 center, 2 right
  int mt, mb, pl, pr;          // margins/padding in cells
  int width;                   // -1 auto, else cells
  // layout result
  int x, y, w, h;
} Node;

static Node N[MAXNODES];
static int nnodes = 0;

static char arena[1 << 18];
static int arena_off = 0;
static char *astr(const char *s, int len) {
  if (arena_off + len + 1 > (int)sizeof arena) len = sizeof arena - arena_off - 1;
  char *p = arena + arena_off;
  memcpy(p, s, len); p[len] = 0; arena_off += len + 1;
  return p;
}

static int newnode(int is_elem) {
  if (nnodes >= MAXNODES) {
    fprintf(stderr, "web: DOM node limit (%d) exceeded\n", MAXNODES);
    exit(1);
  }
  int i = nnodes++;
  memset(&N[i], 0, sizeof N[i]);
  N[i].is_elem = is_elem;
  N[i].parent = N[i].child = N[i].sibling = -1;
  N[i].color = -1; N[i].bg = -1; N[i].align = -1; N[i].bold = -1;
  N[i].display = -1; N[i].width = -1;
  return i;
}
static void add_child(int parent, int kid) {
  N[kid].parent = parent;
  if (N[parent].child < 0) { N[parent].child = kid; return; }
  int c = N[parent].child;
  while (N[c].sibling >= 0) c = N[c].sibling;
  N[c].sibling = kid;
}
static const char *attrval(int n, const char *name) {
  for (int i = 0; i < N[n].nattr; i++)
    if (strcmp(N[n].attr[i].name, name) == 0) return N[n].attr[i].val;
  return NULL;
}

static int is_void(const char *t) {
  static const char *v[] = { "br","img","hr","meta","link","input",0 };
  for (int i = 0; v[i]; i++) if (strcmp(t, v[i]) == 0) return 1;
  return 0;
}

// ---- HTML parser ------------------------------------------------------------
// raw-text collector for <style>/<script>: returns CSS text (style) appended to
// `css` buffer; script content is discarded in Stage 1.
static char css_buf[1 << 15];
static int css_len = 0;
static void css_append(const char *s, int len) {
  if (css_len + len + 1 < (int)sizeof css_buf) { memcpy(css_buf + css_len, s, len); css_len += len; css_buf[css_len] = 0; }
}

// collected <script> source (inline + external src), run after layout styling.
// Grown dynamically — bundled apps (React) are hundreds of KB.
static char *js_buf = NULL;
static int js_len = 0, js_cap = 0;
static void js_append(const char *s, int len) {
  if (js_len + len + 2 > js_cap) {
    int new_cap = (js_len + len + 2) * 2;
    char *nb = realloc(js_buf, new_cap);
    if (!nb) { fprintf(stderr, "web: out of memory while buffering <script>\n"); return; }
    js_buf = nb;
    js_cap = new_cap;
  }
  memcpy(js_buf + js_len, s, len); js_len += len;
  js_buf[js_len++] = '\n'; js_buf[js_len] = 0;
}

static void lower(char *s) { for (; *s; s++) *s = tolower((unsigned char)*s); }

// forward decl for <link> stylesheet loading
static char *read_file(const char *path, int *out_len);

static void parse_html(const char *src) {
  int root = newnode(1); strcpy(N[root].tag, "#root");
  int cur = root;
  const char *p = src;
  while (*p) {
    if (*p == '<') {
      if (strncmp(p, "<!--", 4) == 0) {            // comment
        const char *e = strstr(p, "-->"); p = e ? e + 3 : p + strlen(p); continue;
      }
      if (p[1] == '!') { while (*p && *p != '>') p++; if (*p) p++; continue; } // <!doctype>
      if (p[1] == '/') {                            // close tag
        p += 2; char name[16]; int i = 0;
        while (*p && *p != '>' && i < 15) { if (!isspace((unsigned char)*p)) name[i++] = tolower((unsigned char)*p); p++; }
        name[i] = 0; if (*p) p++;
        // pop up to the matching open tag
        int c = cur;
        while (c >= 0 && strcmp(N[c].tag, name) != 0) c = N[c].parent;
        if (c >= 0 && N[c].parent >= 0) cur = N[c].parent;
        continue;
      }
      // open tag
      p++; char name[16]; int i = 0;
      while (*p && !isspace((unsigned char)*p) && *p != '>' && *p != '/' && i < 15) name[i++] = tolower((unsigned char)*p), p++;
      name[i] = 0;
      int el = newnode(1); strncpy(N[el].tag, name, 15);
      // attributes
      while (*p && *p != '>' && *p != '/') {
        while (*p && (isspace((unsigned char)*p))) p++;
        if (*p == '>' || *p == '/') break;
        char an[24]; int ai = 0;
        while (*p && !isspace((unsigned char)*p) && *p != '=' && *p != '>' && *p != '/' && ai < 23) an[ai++] = tolower((unsigned char)*p), p++;
        an[ai] = 0;
        char av[256]; int vi = 0; av[0] = 0;
        while (*p && isspace((unsigned char)*p)) p++;
        if (*p == '=') {
          p++; while (*p && isspace((unsigned char)*p)) p++;
          char q = 0; if (*p == '"' || *p == '\'') { q = *p; p++; }
          while (*p && vi < 255 && (q ? *p != q : (!isspace((unsigned char)*p) && *p != '>'))) av[vi++] = *p, p++;
          av[vi] = 0; if (q && *p == q) p++;
        }
        if (an[0] && N[el].nattr < MAXATTRS) {
          strcpy(N[el].attr[N[el].nattr].name, an);
          strncpy(N[el].attr[N[el].nattr].val, av, 255);
          N[el].nattr++;
        }
      }
      int selfclose = (*p == '/');
      while (*p && *p != '>') p++; if (*p) p++;
      add_child(cur, el);

      if (strcmp(name, "style") == 0) {             // raw CSS
        const char *e = strstr(p, "</style>");
        if (!e) e = p + strlen(p);
        css_append(p, (int)(e - p));
        p = (*e) ? e + 8 : e; continue;
      }
      if (strcmp(name, "script") == 0) {            // collect JS to run later
        const char *src = attrval(el, "src");
        if (src) { int L = 0; char *js = read_file(src, &L); if (js) { js_append(js, L); free(js); } }
        const char *e = strstr(p, "</script>");
        if (!e) e = p + strlen(p);
        if (e > p) js_append(p, (int)(e - p));
        p = (*e) ? e + 9 : e; continue;
      }
      if (strcmp(name, "link") == 0) {              // external stylesheet
        const char *rel = attrval(el, "rel"), *href = attrval(el, "href");
        if (rel && href && strstr(rel, "stylesheet")) {
          int L = 0; char *css = read_file(href, &L);
          if (css) { css_append(css, L); free(css); }
        }
      }
      if (!selfclose && !is_void(name)) cur = el;
      continue;
    }
    // text run
    const char *start = p;
    while (*p && *p != '<') p++;
    int len = (int)(p - start);
    // skip whitespace-only text between block tags (keeps the tree tidy)
    int allws = 1; for (int k = 0; k < len; k++) if (!isspace((unsigned char)start[k])) { allws = 0; break; }
    if (!allws) {
      int tn = newnode(0);
      N[tn].text = astr(start, len);
      add_child(cur, tn);
    }
  }
}

// ---- CSS --------------------------------------------------------------------
typedef struct { char prop[24]; char val[120]; } Decl;
typedef struct {
  char sel[MAXSEL][40]; int nsel;     // comma-separated simple selectors
  Decl decl[MAXDECLS]; int ndecl;
  int order;                          // source order, for tie-breaks
} Rule;
static Rule R[MAXRULES];
static int nrules = 0;

static void trim(char *s) {
  int n = (int)strlen(s);
  while (n && isspace((unsigned char)s[n - 1])) s[--n] = 0;
  int i = 0; while (s[i] && isspace((unsigned char)s[i])) i++;
  if (i) memmove(s, s + i, strlen(s + i) + 1);
}

static void parse_css(const char *css) {
  const char *p = css;
  while (*p) {
    while (*p && isspace((unsigned char)*p)) p++;
    if (!*p) break;
    if (strncmp(p, "/*", 2) == 0) { const char *e = strstr(p, "*/"); p = e ? e + 2 : p + strlen(p); continue; }
    // selector list up to '{'
    const char *b = strchr(p, '{');
    if (!b) break;
    if (nrules >= MAXRULES) break;
    Rule *r = &R[nrules];
    memset(r, 0, sizeof *r); r->order = nrules;
    char sels[256]; int sl = (int)(b - p); if (sl > 255) sl = 255;
    memcpy(sels, p, sl); sels[sl] = 0;
    // split on commas
    char *tok = strtok(sels, ",");
    while (tok && r->nsel < MAXSEL) { trim(tok); if (*tok) { strncpy(r->sel[r->nsel++], tok, 39); } tok = strtok(NULL, ","); }
    // body up to '}'
    const char *e = strchr(b, '}');
    if (!e) e = b + strlen(b);
    char body[1024]; int bl = (int)(e - b - 1); if (bl < 0) bl = 0; if (bl > 1023) bl = 1023;
    memcpy(body, b + 1, bl); body[bl] = 0;
    char *d = strtok(body, ";");
    while (d && r->ndecl < MAXDECLS) {
      char *colon = strchr(d, ':');
      if (colon) {
        *colon = 0; char *prop = d, *val = colon + 1; trim(prop); trim(val); lower(prop);
        strncpy(r->decl[r->ndecl].prop, prop, 23);
        strncpy(r->decl[r->ndecl].val, val, 119);
        r->ndecl++;
      }
      d = strtok(NULL, ";");
    }
    nrules++;
    p = (*e) ? e + 1 : e;
  }
}

// does simple selector `sel` match node n?  supports tag, .class, #id, *
static int sel_match(const char *sel, int n) {
  if (strcmp(sel, "*") == 0) return 1;
  if (sel[0] == '.') {
    const char *cls = attrval(n, "class");
    if (!cls) return 0;
    // class list match
    const char *want = sel + 1; int wl = (int)strlen(want);
    const char *c = cls;
    while (*c) {
      while (*c == ' ') c++;
      const char *s = c; while (*c && *c != ' ') c++;
      if ((int)(c - s) == wl && strncmp(s, want, wl) == 0) return 1;
    }
    return 0;
  }
  if (sel[0] == '#') {
    const char *id = attrval(n, "id");
    return id && strcmp(id, sel + 1) == 0;
  }
  return N[n].is_elem && strcmp(N[n].tag, sel) == 0;
}
static int specificity(const char *sel) {
  if (sel[0] == '#') return 100;
  if (sel[0] == '.') return 10;
  if (strcmp(sel, "*") == 0) return 0;
  return 1;
}

// ---- style application ------------------------------------------------------
static int len_to_cells(const char *v) {
  // accepts "12px", "2em", "0", bare number(px); returns cells
  double num = atof(v);
  if (strstr(v, "em")) return (int)(num + 0.5);          // 1em ~= 1 cell
  return (int)(num / PX_PER_CELL + 0.5);                  // px
}
static void apply_decl(int n, const char *prop, const char *val) {
  if (strcmp(prop, "display") == 0) {
    if (strcmp(val, "none") == 0) N[n].display = 2;
    else if (strcmp(val, "inline") == 0) N[n].display = 1;
    else N[n].display = 0;
  } else if (strcmp(prop, "color") == 0) {
    int c = parse_color(val); if (c >= 0) N[n].color = c;
  } else if (strcmp(prop, "background") == 0 || strcmp(prop, "background-color") == 0) {
    int c = parse_color(val); if (c >= 0) N[n].bg = c;
  } else if (strcmp(prop, "text-align") == 0) {
    N[n].align = (strcmp(val, "center") == 0) ? 1 : (strcmp(val, "right") == 0) ? 2 : 0;
  } else if (strcmp(prop, "font-weight") == 0) {
    N[n].bold = (strcmp(val, "bold") == 0 || atoi(val) >= 600) ? 1 : 0;
  } else if (strcmp(prop, "margin") == 0) {
    int c = len_to_cells(val); N[n].mt = c; N[n].mb = c;
  } else if (strcmp(prop, "margin-top") == 0) { N[n].mt = len_to_cells(val);
  } else if (strcmp(prop, "margin-bottom") == 0) { N[n].mb = len_to_cells(val);
  } else if (strcmp(prop, "padding") == 0) { int c = len_to_cells(val); N[n].pl = c; N[n].pr = c;
  } else if (strcmp(prop, "padding-left") == 0) { N[n].pl = len_to_cells(val);
  } else if (strcmp(prop, "padding-right") == 0) { N[n].pr = len_to_cells(val);
  } else if (strcmp(prop, "width") == 0) { N[n].width = len_to_cells(val);
  }
}

// user-agent defaults by tag
static void ua_default(int n) {
  const char *t = N[n].tag;
  if (!N[n].is_elem) { N[n].display = 1; return; }   // text is inline
  // block-level by default
  N[n].display = 0;
  if (!strcmp(t, "span") || !strcmp(t, "a") || !strcmp(t, "strong") || !strcmp(t, "b") ||
      !strcmp(t, "em") || !strcmp(t, "i") || !strcmp(t, "code")) N[n].display = 1;
  if (!strcmp(t, "head")) N[n].display = 2;
  if (!strcmp(t, "h1") || !strcmp(t, "h2") || !strcmp(t, "h3") ||
      !strcmp(t, "strong") || !strcmp(t, "b")) N[n].bold = 1;
  if (!strcmp(t, "a")) N[n].color = 11;              // blue links
  if (!strcmp(t, "p") || !strcmp(t, "h1") || !strcmp(t, "h2") || !strcmp(t, "h3") ||
      !strcmp(t, "ul")) { N[n].mt = 1; N[n].mb = 1; }
  if (!strcmp(t, "li")) N[n].pl = 0;
  if (!strcmp(t, "body")) N[n].pl = 1;
}

static void style_node(int n) {
  ua_default(n);
  // author rules: apply lowest specificity first so higher overrides
  // (simple bubble by (specificity, order))
  for (int pass_spec = 0; pass_spec <= 100; pass_spec++) {
    for (int ri = 0; ri < nrules; ri++) {
      for (int si = 0; si < R[ri].nsel; si++) {
        if (specificity(R[ri].sel[si]) == pass_spec && sel_match(R[ri].sel[si], n)) {
          for (int di = 0; di < R[ri].ndecl; di++)
            apply_decl(n, R[ri].decl[di].prop, R[ri].decl[di].val);
          break;
        }
      }
    }
  }
  // inline style="" wins
  const char *st = N[n].is_elem ? attrval(n, "style") : NULL;
  if (st) {
    char buf[256]; strncpy(buf, st, 255); buf[255] = 0;
    char *d = strtok(buf, ";");
    while (d) {
      char *colon = strchr(d, ':');
      if (colon) { *colon = 0; char *pr = d, *vl = colon + 1; trim(pr); trim(vl); lower(pr); apply_decl(n, pr, vl); }
      d = strtok(NULL, ";");
    }
  }
}

// inherit color/bold/align from parent where unset
static void inherit(int n, int pcolor, int pbold, int palign) {
  if (N[n].color < 0) N[n].color = pcolor;
  if (N[n].bold < 0) N[n].bold = pbold;
  if (N[n].align < 0) N[n].align = palign;
  for (int c = N[n].child; c >= 0; c = N[c].sibling)
    inherit(c, N[n].color, N[n].bold, N[n].align);
}

static void style_node(int n);   // fwd
static int find_tag(int n, const char *tag);

static void full_restyle(void) {
  for (int i = 0; i < nnodes; i++) style_node(i);
  inherit(0, COL_BLACK, 0, 0);
}

// ---- DOM mutation helpers (shared by the JS bindings) ----------------------
static void set_attr(int n, const char *name, const char *val) {
  for (int i = 0; i < N[n].nattr; i++)
    if (!strcmp(N[n].attr[i].name, name)) { strncpy(N[n].attr[i].val, val, 255); N[n].attr[i].val[255] = 0; return; }
  if (N[n].nattr < MAXATTRS) {
    strncpy(N[n].attr[N[n].nattr].name, name, 23); N[n].attr[N[n].nattr].name[23] = 0;
    strncpy(N[n].attr[N[n].nattr].val, val, 255); N[n].attr[N[n].nattr].val[255] = 0;
    N[n].nattr++;
  }
}
static void set_text_content(int n, const char *s) {
  if (!N[n].is_elem) { N[n].text = astr(s, (int)strlen(s)); return; }  // text node
  N[n].child = -1;                       // drop existing children (nodes leak; fine)
  int t = newnode(0); N[t].text = astr(s, (int)strlen(s)); add_child(n, t);
}
// unlink child from parent's sibling list
static void remove_child(int parent, int child) {
  int c = N[parent].child;
  if (c == child) N[parent].child = N[child].sibling;
  else { while (c >= 0 && N[c].sibling != child) c = N[c].sibling; if (c >= 0) N[c].sibling = N[child].sibling; }
  N[child].sibling = -1; N[child].parent = -1;
}
// insert `child` (assumed detached) before `ref`; ref<0 appends
static void insert_before(int parent, int child, int ref) {
  N[child].parent = parent; N[child].sibling = -1;
  if (ref < 0) { add_child(parent, child); return; }
  if (N[parent].child == ref) { N[child].sibling = ref; N[parent].child = child; return; }
  int c = N[parent].child;
  while (c >= 0 && N[c].sibling != ref) c = N[c].sibling;
  if (c >= 0) { N[child].sibling = ref; N[c].sibling = child; } else add_child(parent, child);
}
static void append_inline_style(int n, const char *prop, const char *val) {
  const char *cur = attrval(n, "style");
  char buf[256];
  snprintf(buf, sizeof buf, "%s%s%s:%s;", cur ? cur : "", (cur && *cur) ? " " : "", prop, val);
  set_attr(n, "style", buf);
}
static void gather_text(int n, char *buf, int *len, int cap) {
  if (!N[n].is_elem) { const char *t = N[n].text; while (t && *t && *len < cap - 1) buf[(*len)++] = *t++; return; }
  for (int c = N[n].child; c >= 0; c = N[c].sibling) gather_text(c, buf, len, cap);
}

// ---- JavaScript via QuickJS (optional: -DWEB_JS) ---------------------------
#ifdef WEB_JS
#include "quickjs.h"

static JSClassID node_cid, style_cid;
static JSClassDef node_class_def = { "DOMNode" };
static JSClassDef style_class_def = { "DOMStyle" };

// the JS runtime/context persists across frames so DOM state (React hooks, etc.)
// survives between events; set up once per web_init().
static JSRuntime *G_rt;
static JSContext *G_ctx;

// event listeners registered via addEventListener: one handler per (node,type),
// replaced on re-add (React re-renders re-attach a fresh onClick closure).
typedef struct { int node; char type[16]; JSValue fn; } Listener;
static Listener LISTENERS[MAXLISTENERS];
static int nlisteners;
static int find_listener(int node, const char *type) {
  for (int i = 0; i < nlisteners; i++)
    if (LISTENERS[i].node == node && !strcmp(LISTENERS[i].type, type)) return i;
  return -1;
}

static int opaque_idx(JSValueConst v, JSClassID cid) {
  void *p = JS_GetOpaque(v, cid);
  return p ? (int)(intptr_t)p - 1 : -1;
}
static JSValue make_node(JSContext *ctx, int idx) {
  if (idx < 0) return JS_NULL;
  JSValue o = JS_NewObjectClass(ctx, node_cid);
  JS_SetOpaque(o, (void *)(intptr_t)(idx + 1));
  return o;
}

static JSValue js_getAttribute(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_NULL;
  const char *name = JS_ToCString(ctx, argv[0]); if (!name) return JS_NULL;
  const char *v = attrval(n, name); JS_FreeCString(ctx, name);
  return v ? JS_NewString(ctx, v) : JS_NULL;
}
static JSValue js_setAttribute(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_UNDEFINED;
  const char *name = JS_ToCString(ctx, argv[0]); const char *val = JS_ToCString(ctx, argv[1]);
  if (name && val) set_attr(n, name, val);
  if (name) JS_FreeCString(ctx, name); if (val) JS_FreeCString(ctx, val);
  return JS_UNDEFINED;
}
static JSValue js_appendChild(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid), c = opaque_idx(argv[0], node_cid);
  if (n >= 0 && c >= 0) { if (N[c].parent >= 0) remove_child(N[c].parent, c); add_child(n, c); }
  return JS_DupValue(ctx, argv[0]);
}
static JSValue js_insertBefore(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid), c = opaque_idx(argv[0], node_cid), r = opaque_idx(argv[1], node_cid);
  if (n >= 0 && c >= 0) { if (N[c].parent >= 0) remove_child(N[c].parent, c); insert_before(n, c, r); }
  return JS_DupValue(ctx, argv[0]);
}
static JSValue js_removeChild(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid), c = opaque_idx(argv[0], node_cid);
  if (n >= 0 && c >= 0) remove_child(n, c);
  return JS_DupValue(ctx, argv[0]);
}
static JSValue js_get_nodeValue(JSContext *ctx, JSValueConst t) {
  int n = opaque_idx(t, node_cid);
  if (n < 0 || N[n].is_elem || !N[n].text) return JS_NULL;
  return JS_NewString(ctx, N[n].text);
}
static JSValue js_set_nodeValue(JSContext *ctx, JSValueConst t, JSValueConst v) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_UNDEFINED;
  const char *s = JS_ToCString(ctx, v); if (s) { set_text_content(n, s); JS_FreeCString(ctx, s); }
  return JS_UNDEFINED;
}
static JSValue js_createTextNode(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *s = JS_ToCString(ctx, argv[0]);
  int i = newnode(0); N[i].text = astr(s ? s : "", s ? (int)strlen(s) : 0);
  if (s) JS_FreeCString(ctx, s);
  return make_node(ctx, i);
}
static JSValue js_addEventListener(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_UNDEFINED;
  const char *type = JS_ToCString(ctx, argv[0]); if (!type) return JS_UNDEFINED;
  if (argc > 1 && JS_IsFunction(ctx, argv[1])) {
    int idx = find_listener(n, type);
    if (idx < 0 && nlisteners < MAXLISTENERS) {
      idx = nlisteners++; LISTENERS[idx].node = n;
      strncpy(LISTENERS[idx].type, type, 15); LISTENERS[idx].type[15] = 0;
      LISTENERS[idx].fn = JS_UNDEFINED;
    }
    if (idx >= 0) {
      if (!JS_IsUndefined(LISTENERS[idx].fn)) JS_FreeValue(ctx, LISTENERS[idx].fn);
      LISTENERS[idx].fn = JS_DupValue(ctx, argv[1]);
    }
  }
  JS_FreeCString(ctx, type);
  return JS_UNDEFINED;
}
static JSValue js_removeEventListener(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_UNDEFINED;
  const char *type = JS_ToCString(ctx, argv[0]); if (!type) return JS_UNDEFINED;
  int idx = find_listener(n, type);
  if (idx >= 0) {
    if (!JS_IsUndefined(LISTENERS[idx].fn)) JS_FreeValue(ctx, LISTENERS[idx].fn);
    LISTENERS[idx] = LISTENERS[--nlisteners];
  }
  JS_FreeCString(ctx, type);
  return JS_UNDEFINED;
}
static JSValue js_get_textContent(JSContext *ctx, JSValueConst t) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_NewString(ctx, "");
  char buf[4096]; int len = 0; gather_text(n, buf, &len, sizeof buf); buf[len] = 0;
  return JS_NewString(ctx, buf);
}
static JSValue js_set_textContent(JSContext *ctx, JSValueConst t, JSValueConst v) {
  int n = opaque_idx(t, node_cid); if (n < 0) return JS_UNDEFINED;
  const char *s = JS_ToCString(ctx, v); if (s) { set_text_content(n, s); JS_FreeCString(ctx, s); }
  return JS_UNDEFINED;
}
static JSValue js_get_style(JSContext *ctx, JSValueConst t) {
  int n = opaque_idx(t, node_cid);
  JSValue o = JS_NewObjectClass(ctx, style_cid);
  JS_SetOpaque(o, (void *)(intptr_t)(n + 1));
  return o;
}
// one setter shared by the style properties, dispatched on `magic`
static JSValue js_style_set(JSContext *ctx, JSValueConst t, JSValueConst v, int magic) {
  int n = opaque_idx(t, style_cid); if (n < 0) return JS_UNDEFINED;
  const char *s = JS_ToCString(ctx, v);
  if (s) {
    const char *prop = magic == 0 ? "color" : magic == 1 ? "background-color" : "background";
    append_inline_style(n, prop, s); JS_FreeCString(ctx, s);
  }
  return JS_UNDEFINED;
}
static JSValue js_style_get(JSContext *ctx, JSValueConst t, int magic) { return JS_NewString(ctx, ""); }

static JSValue js_getElementById(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *id = JS_ToCString(ctx, argv[0]); if (!id) return JS_NULL;
  int found = -1;
  for (int i = 0; i < nnodes; i++) {
    const char *a = N[i].is_elem ? attrval(i, "id") : NULL;
    if (a && !strcmp(a, id)) { found = i; break; }
  }
  JS_FreeCString(ctx, id);
  return make_node(ctx, found);
}
static JSValue js_querySelector(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *sel = JS_ToCString(ctx, argv[0]); if (!sel) return JS_NULL;
  int found = -1;
  for (int i = 0; i < nnodes; i++) if (N[i].is_elem && sel_match(sel, i)) { found = i; break; }
  JS_FreeCString(ctx, sel);
  return make_node(ctx, found);
}
static JSValue js_createElement(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *tag = JS_ToCString(ctx, argv[0]); if (!tag) return JS_NULL;
  int i = newnode(1); strncpy(N[i].tag, tag, 15);
  for (char *p = N[i].tag; *p; p++) *p = tolower((unsigned char)*p);
  JS_FreeCString(ctx, tag);
  return make_node(ctx, i);
}
static JSValue js_get_body(JSContext *ctx, JSValueConst t) { return make_node(ctx, find_tag(0, "body")); }
static JSValue js_console_log(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  for (int i = 0; i < argc; i++) {
    const char *s = JS_ToCString(ctx, argv[i]);
    fprintf(stderr, "%s%s", i ? " " : "", s ? s : "");
    if (s) JS_FreeCString(ctx, s);
  }
  fprintf(stderr, "\n");
  return JS_UNDEFINED;
}

// drain the job queue (Promises / microtasks / React's scheduler callbacks)
static void drain_jobs(void) {
  JSContext *c1;
  for (;;) {
    int rc = JS_ExecutePendingJob(G_rt, &c1);
    if (rc <= 0) {
      if (rc < 0) { JSValue e = JS_GetException(c1); const char *s = JS_ToCString(c1, e);
        fprintf(stderr, "JS job error: %s\n", s ? s : "?"); if (s) JS_FreeCString(c1, s); JS_FreeValue(c1, e); }
      break;
    }
  }
}

// create the persistent runtime/context and register the DOM bindings (once).
static void js_setup(void) {
  JSContext *ctx = G_ctx;
  JS_NewClassID(G_rt, &node_cid);  JS_NewClass(G_rt, node_cid, &node_class_def);
  JS_NewClassID(G_rt, &style_cid); JS_NewClass(G_rt, style_cid, &style_class_def);

  // node prototype: methods + textContent/nodeValue/style accessors
  JSValue np = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, np, "getAttribute", JS_NewCFunction(ctx, js_getAttribute, "getAttribute", 1));
  JS_SetPropertyStr(ctx, np, "setAttribute", JS_NewCFunction(ctx, js_setAttribute, "setAttribute", 2));
  JS_SetPropertyStr(ctx, np, "appendChild", JS_NewCFunction(ctx, js_appendChild, "appendChild", 1));
  JS_SetPropertyStr(ctx, np, "insertBefore", JS_NewCFunction(ctx, js_insertBefore, "insertBefore", 2));
  JS_SetPropertyStr(ctx, np, "removeChild", JS_NewCFunction(ctx, js_removeChild, "removeChild", 1));
  JS_SetPropertyStr(ctx, np, "addEventListener", JS_NewCFunction(ctx, js_addEventListener, "addEventListener", 2));
  JS_SetPropertyStr(ctx, np, "removeEventListener", JS_NewCFunction(ctx, js_removeEventListener, "removeEventListener", 2));
  JSAtom a;
  a = JS_NewAtom(ctx, "textContent");
  JS_DefinePropertyGetSet(ctx, np, a,
    JS_NewCFunction2(ctx, (JSCFunction *)js_get_textContent, "get textContent", 0, JS_CFUNC_getter, 0),
    JS_NewCFunction2(ctx, (JSCFunction *)js_set_textContent, "set textContent", 1, JS_CFUNC_setter, 0),
    JS_PROP_C_W_E); JS_FreeAtom(ctx, a);
  a = JS_NewAtom(ctx, "nodeValue");
  JS_DefinePropertyGetSet(ctx, np, a,
    JS_NewCFunction2(ctx, (JSCFunction *)js_get_nodeValue, "get nodeValue", 0, JS_CFUNC_getter, 0),
    JS_NewCFunction2(ctx, (JSCFunction *)js_set_nodeValue, "set nodeValue", 1, JS_CFUNC_setter, 0),
    JS_PROP_C_W_E); JS_FreeAtom(ctx, a);
  a = JS_NewAtom(ctx, "style");
  JS_DefinePropertyGetSet(ctx, np, a,
    JS_NewCFunction2(ctx, (JSCFunction *)js_get_style, "get style", 0, JS_CFUNC_getter, 0),
    JS_UNDEFINED, JS_PROP_C_W_E); JS_FreeAtom(ctx, a);
  JS_SetClassProto(ctx, node_cid, np);

  // style prototype: color / backgroundColor / background setters
  JSValue sp = JS_NewObject(ctx);
  static const char *snames[3] = { "color", "backgroundColor", "background" };
  for (int m = 0; m < 3; m++) {
    a = JS_NewAtom(ctx, snames[m]);
    JS_DefinePropertyGetSet(ctx, sp, a,
      JS_NewCFunction2(ctx, (JSCFunction *)js_style_get, "get", 0, JS_CFUNC_getter_magic, m),
      JS_NewCFunction2(ctx, (JSCFunction *)js_style_set, "set", 1, JS_CFUNC_setter_magic, m),
      JS_PROP_C_W_E); JS_FreeAtom(ctx, a);
  }
  JS_SetClassProto(ctx, style_cid, sp);

  JSValue glob = JS_GetGlobalObject(ctx);
  JSValue doc = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, doc, "getElementById", JS_NewCFunction(ctx, js_getElementById, "getElementById", 1));
  JS_SetPropertyStr(ctx, doc, "querySelector", JS_NewCFunction(ctx, js_querySelector, "querySelector", 1));
  JS_SetPropertyStr(ctx, doc, "createElement", JS_NewCFunction(ctx, js_createElement, "createElement", 1));
  JS_SetPropertyStr(ctx, doc, "createTextNode", JS_NewCFunction(ctx, js_createTextNode, "createTextNode", 1));
  a = JS_NewAtom(ctx, "body");
  JS_DefinePropertyGetSet(ctx, doc, a,
    JS_NewCFunction2(ctx, (JSCFunction *)js_get_body, "get body", 0, JS_CFUNC_getter, 0),
    JS_UNDEFINED, JS_PROP_C_W_E); JS_FreeAtom(ctx, a);
  JS_SetPropertyStr(ctx, glob, "document", doc);

  JSValue con = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, con, "log", JS_NewCFunction(ctx, js_console_log, "log", 1));
  JS_SetPropertyStr(ctx, glob, "console", con);
  JS_FreeValue(ctx, glob);

  // minimal timer shims: there is no macrotask event loop, so map timers onto
  // the microtask queue (drained after each frame). Enough for React's scheduler.
  static const char *PRELUDE =
    "globalThis.setTimeout=function(f){if(typeof f==='function')Promise.resolve().then(f);return 0;};"
    "globalThis.clearTimeout=function(){};"
    "globalThis.setInterval=function(){return 0;};"
    "globalThis.clearInterval=function(){};"
    "globalThis.queueMicrotask=globalThis.queueMicrotask||function(f){Promise.resolve().then(f);};";
  JSValue pr = JS_Eval(ctx, PRELUDE, strlen(PRELUDE), "<prelude>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, pr);
}

// run the collected <script> against the DOM (keeps the context alive), restyle
static void js_run(void) {
  if (js_len == 0) return;
  G_rt = JS_NewRuntime();
  G_ctx = JS_NewContext(G_rt);
  js_setup();
  JSValue r = JS_Eval(G_ctx, js_buf, js_len, "<script>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(r)) {
    JSValue e = JS_GetException(G_ctx);
    const char *s = JS_ToCString(G_ctx, e);
    fprintf(stderr, "JS error: %s\n", s ? s : "?");
    if (s) JS_FreeCString(G_ctx, s);
    JS_FreeValue(G_ctx, e);
  }
  JS_FreeValue(G_ctx, r);
  drain_jobs();
  full_restyle();
}

static void js_teardown(void) {
  if (G_ctx) for (int i = 0; i < nlisteners; i++)
    if (!JS_IsUndefined(LISTENERS[i].fn)) JS_FreeValue(G_ctx, LISTENERS[i].fn);
  nlisteners = 0;
  if (G_ctx) { JS_FreeContext(G_ctx); G_ctx = NULL; }
  if (G_rt) { JS_FreeRuntime(G_rt); G_rt = NULL; }
}

// dispatch a DOM event: walk from the hit node up to the root, firing the first
// matching listener (bubbling to the nearest handler).
static void dispatch(int node, const char *type) {
  if (!G_ctx) return;
  for (int n = node; n >= 0; n = N[n].parent) {
    int idx = find_listener(n, type);
    if (idx >= 0 && !JS_IsUndefined(LISTENERS[idx].fn)) {
      JSValue r = JS_Call(G_ctx, LISTENERS[idx].fn, JS_UNDEFINED, 0, NULL);
      if (JS_IsException(r)) { JSValue e = JS_GetException(G_ctx); const char *s = JS_ToCString(G_ctx, e);
        fprintf(stderr, "event handler error: %s\n", s ? s : "?"); if (s) JS_FreeCString(G_ctx, s); JS_FreeValue(G_ctx, e); }
      JS_FreeValue(G_ctx, r);
      return;
    }
  }
}

// after an event, let React commit synchronously (the bundle exposes
// __wasmcraft_flush -> reconciler.flushSync), then drain microtasks.
static void flush_react(void) {
  if (!G_ctx) return;
  JSValue glob = JS_GetGlobalObject(G_ctx);
  JSValue f = JS_GetPropertyStr(G_ctx, glob, "__wasmcraft_flush");
  if (JS_IsFunction(G_ctx, f)) { JSValue r = JS_Call(G_ctx, f, JS_UNDEFINED, 0, NULL); JS_FreeValue(G_ctx, r); }
  JS_FreeValue(G_ctx, f);
  JS_FreeValue(G_ctx, glob);
  drain_jobs();
}
#else
static void js_run(void) {}
static void js_teardown(void) {}
static void dispatch(int node, const char *type) { (void)node; (void)type; }
static void flush_react(void) {}
#endif

// ---- layout + render --------------------------------------------------------
// We emit directly while laying out: a cursor walks down the page; block boxes
// consume the full content width, inline content wraps into styled word runs.
// Returns the next free row after the subtree.
static int VW;                 // viewport width (cells)

// Inline content is collected into a word list, each word carrying its own
// resolved colour (inherit() already pushed colours down to text nodes), so a
// <span style="color:red"> inside a paragraph keeps its colour through wrapping.
typedef struct { char text[80]; int color; int brk; } Word;
static Word W_[2048];
static int nW;

static void words_reset(void) { nW = 0; }
static void push_word(const char *s, int len, int color) {
  if (nW >= 2048) return;
  if (len > 79) len = 79;
  memcpy(W_[nW].text, s, len); W_[nW].text[len] = 0;
  W_[nW].color = color; W_[nW].brk = 0; nW++;
}
static void push_break(void) { if (nW < 2048) { W_[nW].text[0] = 0; W_[nW].brk = 1; nW++; } }

// gather inline words of a subtree (in document order) into W_
static void collect_words(int n) {
  if (!N[n].is_elem) {
    const char *t = N[n].text;
    while (*t) {
      while (*t && isspace((unsigned char)*t)) t++;
      const char *w = t; while (*t && !isspace((unsigned char)*t)) t++;
      if (t > w) push_word(w, (int)(t - w), N[n].color);
    }
    return;
  }
  if (N[n].display == 2) return;
  if (!strcmp(N[n].tag, "br")) { push_break(); return; }
  for (int c = N[n].child; c >= 0; c = N[c].sibling) collect_words(c);
}

// render the words currently in W_[lo..hi) at (x0,width) from row y; one
// draw_text per word (gaps are background). Returns the row after the content.
static int render_words(int lo, int hi, int x0, int width, int y, int bg, int align) {
  if (width < 1) width = 1;
  int line[256], nl;           // word indices on the current line
  int rows_y = y, i = lo;
  #define EMIT_LINE() do { \
      int ll = 0; for (int k = 0; k < nl; k++) ll += (int)strlen(W_[line[k]].text) + (k ? 1 : 0); \
      int pad = (align == 1) ? (width - ll) / 2 : (align == 2) ? (width - ll) : 0; \
      if (pad < 0) pad = 0; \
      if (bg >= 0) draw_rect(x0, rows_y, width, 1, bg); \
      int x = x0 + pad; \
      for (int k = 0; k < nl; k++) { \
        draw_text(x, rows_y, W_[line[k]].color, bg >= 0 ? bg : COL_WHITE, W_[line[k]].text); \
        x += (int)strlen(W_[line[k]].text) + 1; \
      } \
      rows_y++; nl = 0; \
    } while (0)
  nl = 0; int ll = 0;
  while (i < hi) {
    if (W_[i].brk) { EMIT_LINE(); ll = 0; i++; continue; }
    int wl = (int)strlen(W_[i].text);
    if (nl > 0 && ll + 1 + wl > width) { EMIT_LINE(); ll = 0; }
    if (wl > width && nl == 0) {           // hard-break an over-long word
      // place as much as fits, leaving the remainder as a synthetic next word
      // (simpler: just emit it; the host clips). Emit on its own line.
      line[nl++] = i; ll += wl; EMIT_LINE(); ll = 0; i++; continue;
    }
    line[nl++] = i; ll += (nl > 1 ? 1 : 0) + wl; i++;
    if (nl >= 255) { EMIT_LINE(); ll = 0; }
  }
  if (nl > 0) EMIT_LINE();
  #undef EMIT_LINE
  return rows_y;
}

static int has_block_child(int n) {
  for (int c = N[n].child; c >= 0; c = N[c].sibling)
    if (N[c].is_elem && N[c].display == 0) return 1;
  return 0;
}

// render the pending inline children [0..np) of a block as one wrapped
// paragraph (building W_ fresh, so recursion into block siblings can't clobber
// it). Returns the row after the content; resets *np to 0.
static int flush_inline(int *pending, int *np, int li_prefix, int color,
                        int cx, int cw, int y, int bg, int align) {
  if (*np == 0) return y;
  words_reset();
  if (li_prefix) push_word("-", 1, color);
  for (int i = 0; i < *np; i++) collect_words(pending[i]);
  if (nW > 0) y = render_words(0, nW, cx, cw, y, bg, align);
  *np = 0;
  return y;
}

static int layout_block(int n, int x0, int width, int y) {
  if (N[n].is_elem && N[n].display == 2) return y;
  int cx = x0 + N[n].pl;
  int cw = width - N[n].pl - N[n].pr;
  if (N[n].width >= 0 && N[n].width < cw) cw = N[n].width;
  if (cw < 1) cw = 1;
  y += N[n].mt;
  int ys = y;                    // content top, for the element's hit rect
  int is_li = N[n].is_elem && !strcmp(N[n].tag, "li");
  if (has_block_child(n)) {
    // accumulate consecutive inline children, flushing before each block child
    int pending[512], np = 0, li_done = 0;
    for (int c = N[n].child; c >= 0; c = N[c].sibling) {
      if (N[c].is_elem && N[c].display == 0) {
        y = flush_inline(pending, &np, is_li && !li_done, N[n].color, cx, cw, y, N[n].bg, N[n].align);
        li_done = 1;
        y = layout_block(c, cx, cw, y);
      } else if (np < 512) {
        pending[np++] = c;
      }
    }
    y = flush_inline(pending, &np, is_li && !li_done, N[n].color, cx, cw, y, N[n].bg, N[n].align);
  } else {
    // leaf block: render its inline content as one wrapped paragraph
    words_reset();
    if (is_li) push_word("-", 1, N[n].color);
    collect_words(n);
    if (nW > 0 || N[n].bg >= 0) y = render_words(0, nW, cx, cw, y, N[n].bg, N[n].align);
  }
  if (N[n].is_elem) { N[n].x = cx; N[n].y = ys; N[n].w = cw; N[n].h = (y > ys) ? y - ys : 1; }
  y += N[n].mb;
  return y;
}

// ---- file IO ----------------------------------------------------------------
static char *read_file(const char *path, int *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
  if (sz < 0) sz = 0;
  char *buf = malloc(sz + 1);
  if (!buf) { fclose(f); return NULL; }
  size_t n = fread(buf, 1, sz, f); buf[n] = 0; fclose(f);
  if (out_len) *out_len = (int)n;
  return buf;
}

// find the <body> (or #root) to lay out, and a tag's first match helper
static int find_tag(int n, const char *tag) {
  if (N[n].is_elem && !strcmp(N[n].tag, tag)) return n;
  for (int c = N[n].child; c >= 0; c = N[c].sibling) {
    int r = find_tag(c, tag); if (r >= 0) return r;
  }
  return -1;
}

// lay out the current DOM and emit one frame of the draw protocol. A dry pass
// measures the height (so SIZE is exact) and records each element's hit rect.
static void emit_frame(void) {
  int body = find_tag(0, "body");
  if (body < 0) body = 0;
  draw_suppress = 1;
  int h = layout_block(body, 0, VW, 0);
  draw_suppress = 0;
  if (h < 1) h = 1;
  draw_size(VW, h);
  draw_clear(COL_WHITE);
  layout_block(body, 0, VW, 0);   // records N[].x/y/w/h for hit-testing
  draw_frame_end();
  fflush(stdout);                 // push the frame to the host before we block
}

// deepest (smallest-area) element rect containing the cell (x,y)
static int hit_test(int x, int y) {
  int best = -1, bestarea = 1 << 30;
  for (int i = 0; i < nnodes; i++) {
    if (!N[i].is_elem || N[i].w <= 0 || N[i].h <= 0) continue;
    if (x >= N[i].x && x < N[i].x + N[i].w && y >= N[i].y && y < N[i].y + N[i].h) {
      int area = N[i].w * N[i].h;
      if (area <= bestarea) { bestarea = area; best = i; }
    }
  }
  return best;
}

static void reset_all(void) {
  js_teardown();
  nnodes = 0; css_len = 0; css_buf[0] = 0; js_len = 0; if (js_buf) js_buf[0] = 0; arena_off = 0;
}

EXPORT("web_malloc") void *web_malloc(int n) { return malloc(n); }
EXPORT("web_free") void web_free(void *p) { free(p); }

// (re)load a page and render the first frame. width = viewport columns.
EXPORT("web_init") void web_init(const char *page, int width) {
  reset_all();
  VW = width >= 4 ? width : 51;
  int L = 0; char *html = read_file(page, &L);
  if (!html) {
    draw_size(VW, 1); draw_clear(COL_WHITE);
    char msg[160]; snprintf(msg, sizeof msg, "browser: cannot open %s", page);
    draw_text(0, 0, COL_RED, COL_WHITE, msg);
    draw_frame_end(); fflush(stdout);
    return;
  }
  parse_html(html);
  parse_css(css_buf);
  for (int i = 0; i < nnodes; i++) style_node(i);
  inherit(0, COL_BLACK, 0, 0);   // root: black text, not bold, left-aligned
  js_run();                      // run <script> (mutates the DOM, then restyles)
  free(html);
  emit_frame();
}

// deliver an event at cell (x,y): dispatch to the DOM, let React re-render, and
// emit the updated frame. `type` is e.g. "click".
EXPORT("web_event") void web_event(const char *type, int x, int y) {
  int node = hit_test(x, y);
  if (node >= 0) dispatch(node, type);
  flush_react();
  full_restyle();
  emit_frame();
}

// kept so a command-model build still works (run.lua); the reactor build uses
// _initialize + web_init/web_event instead.
int main(int argc, char **argv) {
  web_init(argc > 1 ? argv[1] : "index.html", argc > 2 ? atoi(argv[2]) : 51);
  return 0;
}
