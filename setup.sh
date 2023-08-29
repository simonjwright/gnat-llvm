# Paths etc for brew llvm

# We need to keep gcc/bin at the head of PATH so that when gprbuild
# looks for a C++ compiler it finds g++ rather than clang++.
#
# This is because gprbuild insists on saying -static-libgcc if it's
# linking an executable while there's any trace of C++ in the sources.

export PATH="$(dirname $(which gcc)):$HOMEBREW_PREFIX/opt/llvm/bin:$PATH"
