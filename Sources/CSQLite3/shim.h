// /usr/include/sqlite3.h does not exist on modern macOS; the header lives in
// the SDK sysroot, which swiftc passes via -isysroot. An angled include makes
// the clang module resolver find it there.
#include <sqlite3.h>
