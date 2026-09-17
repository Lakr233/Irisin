#pragma once

// The SDK's own constants, handed to Swift as functions. See module.modulemap
// for why they cannot be named directly in Swift. Nothing is defined here;
// every body is an SDK macro, and every symbol behind them is in libSystem on
// every iOS that has XPC at all.

#include <xpc/xpc.h>
#include <xpc/connection.h>

static inline xpc_type_t irisin_xpc_type_bool(void) { return XPC_TYPE_BOOL; }
static inline xpc_type_t irisin_xpc_type_connection(void) { return XPC_TYPE_CONNECTION; }
static inline xpc_type_t irisin_xpc_type_dictionary(void) { return XPC_TYPE_DICTIONARY; }

static inline xpc_object_t irisin_xpc_error_connection_interrupted(void) {
    return XPC_ERROR_CONNECTION_INTERRUPTED;
}
static inline xpc_object_t irisin_xpc_error_connection_invalid(void) {
    return XPC_ERROR_CONNECTION_INVALID;
}
