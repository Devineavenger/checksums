# stat.sh
# Portable stat wrappers; GNU and BSD variants handled gracefully.

get_inode(){ if [ "$TOOL_stat_gnu" -eq 1 ] ; then stat -c '%i' -- "$1" 2>/dev/null ; else stat -f '%i' -- "$1" 2>/dev/null ; fi }
get_dev(){   if [ "$TOOL_stat_gnu" -eq 1 ] ; then stat -c '%d' -- "$1" 2>/dev/null ; else stat -f '%d' -- "$1" 2>/dev/null ; fi }
get_mtime(){ if [ "$TOOL_stat_gnu" -eq 1 ] ; then stat -c '%Y' -- "$1" 2>/dev/null ; else stat -f '%m' -- "$1" 2>/dev/null ; fi }
get_size(){  if [ "$TOOL_stat_gnu" -eq 1 ] ; then stat -c '%s' -- "$1" 2>/dev/null ; else stat -f '%z' -- "$1" 2>/dev/null ; fi }
