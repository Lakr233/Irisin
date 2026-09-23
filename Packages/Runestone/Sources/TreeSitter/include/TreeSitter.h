#ifndef RUNESTONE_TREESITTER_H
#define RUNESTONE_TREESITTER_H

#include <stdint.h>

/* What Swift imports. Xcode 27's importer skips an incomplete C struct, and
   every tree-sitter handle is one, so each is completed here before api.h
   and imports as a typed pointer. The runtime's own sources include api.h
   directly and never see these. */
struct TSLanguage { uint8_t _runestone_opaque; };
struct TSParser { uint8_t _runestone_opaque; };
struct TSTree { uint8_t _runestone_opaque; };
struct TSQuery { uint8_t _runestone_opaque; };
struct TSQueryCursor { uint8_t _runestone_opaque; };
struct TSLookaheadIterator { uint8_t _runestone_opaque; };

#include "tree_sitter/api.h"

#endif
