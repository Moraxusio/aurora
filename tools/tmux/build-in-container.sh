#!/bin/sh
# Runs inside an Alpine (musl) container: builds tmux fully static with
# libevent and ncurses linked in, plus a small compiled terminfo set.
# Input: /src/*.tar.gz (checked by the caller). Output: /out/{tmux,terminfo.tar.gz,manifest.txt}
set -eu
apk add --no-cache build-base bison pkgconf tar >/dev/null
set -o pipefail

export SOURCE_DATE_EPOCH=1780000000
export CFLAGS="-O2 -pipe -ffile-prefix-map=/build=. -fno-ident"
export LDFLAGS="-Wl,--build-id=none"
J=$(nproc); [ "$J" -gt 32 ] && J=32
TERMS="tmux,tmux-256color,xterm,xterm-256color,screen,screen-256color,vt100,vt220,linux,dumb"
FALLBACKS="tmux-256color,xterm-256color,xterm,screen-256color,screen,linux,vt100,dumb"
rm -rf /build && mkdir -p /build && cd /build

# 1. A throwaway ncurses with tic/infocmp, only to compile terminfo and the
#    built-in fallback entries below (so nothing comes from the host).
tar xzf /src/ncurses-6.6.tar.gz && mv ncurses-6.6 nc1
(cd nc1 && ./configure -q --prefix=/build/s1 --without-shared --without-cxx --without-cxx-binding --without-ada \
   --without-manpages --without-tests --disable-widec >/dev/null && make -s -j$J >/dev/null 2>&1 && make -s install >/dev/null 2>&1)
export TERMINFO=/build/s1/share/terminfo

# 2. The ncurses tmux links: static, terminfo only, the common terminals
#    compiled in, and the aurora terminfo directory searched first.
tar xzf /src/ncurses-6.6.tar.gz && mv ncurses-6.6 nc2
(cd nc2 && ./configure -q --prefix=/build/nc --without-shared --with-normal --with-termlib --disable-widec \
   --without-cxx --without-cxx-binding --without-ada --without-manpages --without-progs --without-tests \
   --enable-pc-files --with-pkg-config-libdir=/build/nc/lib/pkgconfig --disable-db-install \
   --with-terminfo-dirs=/var/lib/aurora/terminfo:/etc/terminfo:/lib/terminfo:/usr/share/terminfo \
   --with-default-terminfo-dir=/usr/share/terminfo --with-fallbacks=$FALLBACKS \
   --with-tic-path=/build/s1/bin/tic --with-infocmp-path=/build/s1/bin/infocmp >/dev/null \
 && make -s -j$J >/dev/null 2>&1 && make -s install >/dev/null 2>&1)

# 3. libevent, static, no TLS.
tar xzf /src/libevent-2.1.13-stable.tar.gz
(cd libevent-2.1.13-stable && ./configure -q --prefix=/build/ev --disable-shared --enable-static --disable-openssl \
   --disable-samples --disable-libevent-regress --disable-debug-mode >/dev/null && make -s -j$J >/dev/null 2>&1 && make -s install >/dev/null 2>&1)

# 4. tmux.
tar xzf /src/tmux-3.8.tar.gz
(cd tmux-3.8 && PKG_CONFIG_PATH=/build/ev/lib/pkgconfig:/build/nc/lib/pkgconfig \
   ./configure -q --enable-static --prefix=/usr --sysconfdir=/etc >/dev/null && make -s -j$J >/dev/null 2>&1)
cp tmux-3.8/tmux /out/tmux
strip --strip-all /out/tmux
if readelf -d /out/tmux 2>/dev/null | grep -q NEEDED; then echo "tmux is not static" >&2; exit 1; fi

# 5. Compiled terminfo for programs inside sessions (TERMINFO_DIRS).
mkdir -p /build/ti
/build/s1/bin/tic -x -o /build/ti -e "$TERMS" nc1/misc/terminfo.src
(cd /build/ti && find . -type f | sort > /build/ti.list && \
 tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner -cf - -T /build/ti.list | gzip -n -9 > /out/terminfo.tar.gz)

# 6. Smoke test with no terminfo on disk at all: only the compiled-in entries.
mkdir -p /tmp/empty
TERMINFO=/tmp/empty TERMINFO_DIRS=/tmp/empty TERM=xterm-256color /out/tmux -u -L smoke -f /dev/null new-session -d -s t -x 80 -y 20 'printf "ok \344\275\240\345\245\275\n"; sleep 30'
sleep 1
TERMINFO=/tmp/empty TERMINFO_DIRS=/tmp/empty TERM=xterm-256color /out/tmux -u -L smoke capture-pane -p -t =t: > /tmp/cap
/out/tmux -L smoke kill-server
grep -q "ok $(printf '\344\275\240\345\245\275')" /tmp/cap || { echo "smoke test failed:"; cat /tmp/cap; exit 1; }

{
  echo "$(/out/tmux -V), static musl build in alpine $(cat /etc/alpine-release), gcc $(gcc -dumpversion)"
  echo "libevent 2.1.13-stable, ncurses 6.6 (fallbacks: $FALLBACKS)"
  echo "terminfo: $TERMS"
  (cd /out && sha256sum tmux terminfo.tar.gz)
} > /out/manifest.txt
cat /out/manifest.txt
