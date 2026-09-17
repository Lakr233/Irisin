// The whole source of the Mach-O fixtures beside it. See build.sh.
#ifdef FIXTURE_DEPENDENCY

int fixture_dependency(void) {
    return 1;
}

#else

extern int fixture_dependency(void);

const char *fixture_path = "/var/jb/Library/Application Support/Fixture";

int fixture_entry(void) {
    return fixture_dependency();
}

#ifdef FIXTURE_EXECUTABLE
int main(void) {
    return fixture_entry();
}
#endif

#endif
