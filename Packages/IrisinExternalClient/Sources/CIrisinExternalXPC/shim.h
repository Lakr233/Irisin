#pragma once

// The SDK's own XPC constants, handed to Swift as functions. Every body is
// an SDK macro over a libSystem global present on every iOS with XPC.

#include <xpc/xpc.h>
#include <xpc/connection.h>

static inline xpc_type_t irisin_external_xpc_type_dictionary(void) { return XPC_TYPE_DICTIONARY; }
static inline xpc_type_t irisin_external_xpc_type_array(void) { return XPC_TYPE_ARRAY; }

static inline xpc_object_t irisin_external_xpc_error_connection_interrupted(void) {
    return XPC_ERROR_CONNECTION_INTERRUPTED;
}
static inline xpc_object_t irisin_external_xpc_error_connection_invalid(void) {
    return XPC_ERROR_CONNECTION_INVALID;
}
