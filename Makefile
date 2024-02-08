export VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo 0.6.3alpha2)

LIBDIR ?= $(shell \
  if 1>/dev/null which systemd-path ; then \
    systemd-path user-library-private ; \
  elif [ ! -z "$(XDG_DATA_HOME)" ] ; then \
    echo "$(XDG_DATA_HOME)/../lib" ; \
  elif [ -d "$(HOME)/.local" ] ; then \
    echo "$(HOME)/.local/lib" ; \
  else echo "/usr/local/lib" ; \
  fi)
PREFIX := $(shell dirname $(LIBDIR))
INCLUDEDIR := $(PREFIX)/include
PCLIBDIR := $(LIBDIR)/pkgconfig

# collect sources
ifneq ($(AMALGAMATED),1)
	SRC := $(wildcard lib/src/*.c)
# do not double-include amalgamation
	SRC := $(filter-out lib/src/lib.c,$(SRC))
else
# use amalgamated build
	SRC := lib/src/lib.c
endif
OBJ := $(SRC:.c=.o)

# define default flags, and override to append mandatory flags
override CFLAGS := -O3 -std=gnu11 -fPIC -fvisibility=hidden -Wall -Wextra -Wshadow -pedantic $(CFLAGS)
override CFLAGS += -Ilib/src -Ilib/src/wasm -Ilib/include

# workaround cflags for old gcc versions
CC_VERSION := $(shell $(CC) -dumpversion)
ifeq ($(CC_VERSION), $(filter $(CC_VERSION),7 8))
override CFLAGS += -Wno-format-truncation
endif

# ABI versioning
SONAME_MAJOR := 0
SONAME_MINOR := 0

# OS-specific bits
ifeq ($(shell uname),Darwin)
	SOEXT = dylib
	SOEXTVER_MAJOR = $(SONAME_MAJOR).dylib
	SOEXTVER = $(SONAME_MAJOR).$(SONAME_MINOR).dylib
	LINKSHARED += -dynamiclib -Wl,-install_name,$(LIBDIR)/libtree-sitter.$(SONAME_MAJOR).$(SOEXT)
else
	SOEXT = so
	SOEXTVER_MAJOR = so.$(SONAME_MAJOR)
	SOEXTVER = so.$(SONAME_MAJOR).$(SONAME_MINOR)
	LINKSHARED += -shared -Wl,-soname,libtree-sitter.$(SOEXT).$(SONAME_MAJOR)
endif
ifneq (,$(filter $(shell uname),FreeBSD NetBSD DragonFly))
	PCLIBDIR := $(PREFIX)/libdata/pkgconfig
endif

.PHONY: all
all: libtree-sitter.$(SOEXTVER)

target/release/libtree_sitter_highlight.$(SOEXT): highlight/src/lib.rs highlight/src/c_lib.rs lib/binding_rust/lib.rs
	( cd highlight ; cargo build --release )

libtree-sitter.$(SOEXTVER): $(OBJ)
	$(CC) $(LDFLAGS) $(LINKSHARED) $^ $(LDLIBS) -o $@
	ln -sf $@ libtree-sitter.$(SOEXT)
	ln -sf $@ libtree-sitter.$(SOEXTVER_MAJOR)
ifneq ($(STRIP),)
	$(STRIP) $@
endif

.PHONY: install-highlight
install-highlight: target/release/libtree_sitter_highlight.$(SOEXT)
	install -d '$(DESTDIR)$(LIBDIR)'
	install -m755 $< '$(DESTDIR)$(LIBDIR)'/$(<F)
	install -d '$(DESTDIR)$(INCLUDEDIR)'/tree_sitter
	install -m644 highlight/include/tree_sitter/*.h '$(DESTDIR)$(INCLUDEDIR)'/tree_sitter/

.PHONY: install-cli
install-cli:
	cd cli ; cargo install --path .

.PHONY: install-grammars
install-grammars: install-cli
	bash -x install-grammars.sh

.PHONY: install-ci
install-ci: all install-highlight
	install -d '$(DESTDIR)$(LIBDIR)'
	install -m755 libtree-sitter.$(SOEXTVER) '$(DESTDIR)$(LIBDIR)'/libtree-sitter.$(SOEXTVER)
	ln -sf libtree-sitter.$(SOEXTVER) '$(DESTDIR)$(LIBDIR)'/libtree-sitter.$(SOEXTVER_MAJOR)
	ln -sf libtree-sitter.$(SOEXTVER) '$(DESTDIR)$(LIBDIR)'/libtree-sitter.$(SOEXT)

	install -d '$(DESTDIR)$(INCLUDEDIR)'/tree_sitter
	install -m644 lib/include/tree_sitter/api.h '$(DESTDIR)$(INCLUDEDIR)'/tree_sitter/

	install -d '$(DESTDIR)$(PCLIBDIR)'
	sed -e 's|@LIBDIR@|$(LIBDIR)|;s|@INCLUDEDIR@|$(INCLUDEDIR)|;s|@VERSION@|$(VERSION)|' \
	    -e 's|=$(PREFIX)|=$${prefix}|' \
	    -e 's|@PREFIX@|$(PREFIX)|' \
	    tree-sitter.pc.in > '$(DESTDIR)$(PCLIBDIR)'/tree-sitter.pc
	PKG_CONFIG_PATH=$(PKG_CONFIG_PATH):'$(DESTDIR)$(PCLIBDIR)' pkg-config --exact-version=$(VERSION) tree-sitter

.PHONY: install
install: install-ci install-grammars
	@echo "!!!"
	@echo "!!!                  USER NOTICE"
	@echo "!!!"
	@echo "!!! Add '$(DESTDIR)$(PCLIBDIR)' to PKG_CONFIG_PATH"
	@echo "!!! Add '$(DESTDIR)$(LIBDIR)' to LD_LIBRARY_PATH"
	@echo "!!!"

.PHONY: clean
clean:
	cargo clean
	rm -rf lib/src/*.o libtree-sitter.$(SOEXT) libtree-sitter.$(SOEXTVER_MAJOR) libtree-sitter.$(SOEXTVER)

.PHONY: very-clean
very-clean: clean
	rm -rf grammars

.PHONY: retag
retag:
	2>/dev/null git tag -d $(VERSION) || true
	2>/dev/null git push --delete origin $(VERSION) || true
	git tag $(VERSION)
	git push origin $(VERSION)
