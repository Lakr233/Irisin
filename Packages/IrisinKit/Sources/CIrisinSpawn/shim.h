#pragma once

// libSystem's spawn calls, without the SDK's availability attributes. See
// module.modulemap for why. Each prototype is the SDK's own (spawn.h), and
// `<spawn.h>` is included only for its types and `POSIX_SPAWN_*` flags.

#include <signal.h>
#include <spawn.h>
#include <sys/types.h>

int irisin_posix_spawn(pid_t *__restrict pid, const char *__restrict path,
                       const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *__restrict attributes,
                       char *const argv[__restrict], char *const envp[__restrict])
    __asm("_posix_spawn");

int irisin_posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions)
    __asm("_posix_spawn_file_actions_init");
int irisin_posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions)
    __asm("_posix_spawn_file_actions_destroy");
int irisin_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions, int descriptor,
                                            int target)
    __asm("_posix_spawn_file_actions_adddup2");
int irisin_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *__restrict actions,
                                            int target, const char *__restrict path, int flags,
                                            mode_t mode)
    __asm("_posix_spawn_file_actions_addopen");
int irisin_posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *__restrict actions,
                                                const char *__restrict path)
    __asm("_posix_spawn_file_actions_addchdir_np");

int irisin_posix_spawnattr_init(posix_spawnattr_t *attributes)
    __asm("_posix_spawnattr_init");
int irisin_posix_spawnattr_destroy(posix_spawnattr_t *attributes)
    __asm("_posix_spawnattr_destroy");
int irisin_posix_spawnattr_setflags(posix_spawnattr_t *attributes, short flags)
    __asm("_posix_spawnattr_setflags");
int irisin_posix_spawnattr_setsigdefault(posix_spawnattr_t *__restrict attributes,
                                         const sigset_t *__restrict signals)
    __asm("_posix_spawnattr_setsigdefault");
int irisin_posix_spawnattr_setsigmask(posix_spawnattr_t *__restrict attributes,
                                      const sigset_t *__restrict signals)
    __asm("_posix_spawnattr_setsigmask");
