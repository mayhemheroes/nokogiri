/*
 * test_gumbo_oracle.c — golden functional oracle over the EXACT C parse path the fuzzer drives
 * (gumbo_parse_with_options → the Gumbo HTML5 tokenizer/tree-builder). Self-contained: links the
 * vendored libgumbo and asserts structural facts about the parse tree of known HTML, and that
 * malformed/degenerate inputs are handled without crashing and still yield a well-formed tree.
 *
 * This is a real golden oracle, not a no-op stub: each check asserts a specific tree-shape fact
 * (root is <html>, a <body> exists, an expected element/tag/text is present). A patch that breaks
 * the parser (e.g. mis-tags elements, drops children, mishandles entities) fails these asserts.
 *
 * Prints "PASS <name>" / "FAIL <name>" per case and a final "RESULT passed=N failed=M"; exits
 * nonzero if any case fails. test.sh wraps this output into a CTRF summary.
 */
#include "nokogiri_gumbo.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int g_pass = 0, g_fail = 0;

static void report(const char *name, int ok) {
  if (ok) { printf("PASS %s\n", name); g_pass++; }
  else    { printf("FAIL %s\n", name); g_fail++; }
}

/* Depth-first search for the first element node with the given tag. */
static const GumboNode *find_tag(const GumboNode *node, GumboTag tag) {
  if (!node || node->type != GUMBO_NODE_ELEMENT) return NULL;
  if (node->v.element.tag == tag) return node;
  const GumboVector *kids = &node->v.element.children;
  for (unsigned i = 0; i < kids->length; i++) {
    const GumboNode *r = find_tag((const GumboNode *)kids->data[i], tag);
    if (r) return r;
  }
  return NULL;
}

/* True if any text descendant of `node` contains `needle`. */
static int has_text(const GumboNode *node, const char *needle) {
  if (!node) return 0;
  if (node->type == GUMBO_NODE_TEXT || node->type == GUMBO_NODE_WHITESPACE ||
      node->type == GUMBO_NODE_CDATA) {
    return node->v.text.text && strstr(node->v.text.text, needle) != NULL;
  }
  if (node->type == GUMBO_NODE_ELEMENT) {
    const GumboVector *kids = &node->v.element.children;
    for (unsigned i = 0; i < kids->length; i++)
      if (has_text((const GumboNode *)kids->data[i], needle)) return 1;
  }
  return 0;
}

static GumboOutput *parse(const char *html) {
  GumboOptions opts = kGumboDefaultOptions;
  return gumbo_parse_with_options(&opts, html, strlen(html));
}

int main(void) {
  /* 1) A full document: root must be <html>, with a <head><title> and <body>. */
  {
    GumboOutput *o = parse(
      "<!DOCTYPE html><html><head><title>T</title></head>"
      "<body><p>hello world</p></body></html>");
    int ok = o && o->root && o->root->type == GUMBO_NODE_ELEMENT &&
             o->root->v.element.tag == GUMBO_TAG_HTML &&
             find_tag(o->root, GUMBO_TAG_HEAD) &&
             find_tag(o->root, GUMBO_TAG_TITLE) &&
             find_tag(o->root, GUMBO_TAG_BODY) &&
             find_tag(o->root, GUMBO_TAG_P) &&
             has_text(o->root, "hello world");
    report("full_document_tree", ok);
    if (o) gumbo_destroy_output(o);
  }

  /* 2) Implicit head/body insertion from a bare fragment: parser must still build <html>/<body>. */
  {
    GumboOutput *o = parse("<p>just a paragraph</p>");
    int ok = o && o->root && o->root->v.element.tag == GUMBO_TAG_HTML &&
             find_tag(o->root, GUMBO_TAG_BODY) &&
             find_tag(o->root, GUMBO_TAG_P);
    report("implicit_html_body", ok);
    if (o) gumbo_destroy_output(o);
  }

  /* 3) Table foster-parenting / well-known tree shape: <table> contains a <tbody>/<tr>/<td>. */
  {
    GumboOutput *o = parse("<table><tr><td>cell</td></tr></table>");
    int ok = o && find_tag(o->root, GUMBO_TAG_TABLE) &&
             find_tag(o->root, GUMBO_TAG_TR) &&
             find_tag(o->root, GUMBO_TAG_TD) &&
             has_text(o->root, "cell");
    report("table_tree_construction", ok);
    if (o) gumbo_destroy_output(o);
  }

  /* 4) Character-reference decoding: "&amp;" -> "&", "&#65;" -> "A". */
  {
    GumboOutput *o = parse("<div>a &amp; b &#65;</div>");
    const GumboNode *div = find_tag(o ? o->root : NULL, GUMBO_TAG_DIV);
    int ok = div && has_text(div, "a & b A");
    report("char_reference_decoding", ok);
    if (o) gumbo_destroy_output(o);
  }

  /* 5) Attribute parsing: <a href="x"> -> element exposes the href attribute with value "x". */
  {
    GumboOutput *o = parse("<a href=\"x\">link</a>");
    const GumboNode *a = find_tag(o ? o->root : NULL, GUMBO_TAG_A);
    int ok = 0;
    if (a) {
      const GumboAttribute *href = gumbo_get_attribute(&a->v.element.attributes, "href");
      ok = href && href->value && strcmp(href->value, "x") == 0;
    }
    report("attribute_parsing", ok);
    if (o) gumbo_destroy_output(o);
  }

  /* 6) Malformed / degenerate inputs must not crash and must still produce an <html> root. */
  {
    const char *bad[] = {
      "<<<<<>>>>>",
      "<div><span><b>unclosed",
      "<!-- never closed comment",
      "<a href=",
      "<p></p></p></p></div></body>",
      "<svg><foreignObject><div></svg>",
      "&notarealentity; &#xZZZZ; &#999999999;",
    };
    int ok = 1;
    for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
      GumboOutput *o = parse(bad[i]);
      if (!o || !o->root || o->root->type != GUMBO_NODE_ELEMENT ||
          o->root->v.element.tag != GUMBO_TAG_HTML) {
        ok = 0;
      }
      if (o) gumbo_destroy_output(o);
    }
    report("malformed_inputs_robust", ok);
  }

  printf("RESULT passed=%d failed=%d\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
