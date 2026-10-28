`upstream-install-release.sh` is the unmodified XTLS/Xray-install installer at
commit `e42df6a772e60dd7b058f852262c4dbeb0bc231d`, retrieved on 2026-10-28:

https://github.com/XTLS/Xray-install/blob/e42df6a772e60dd7b058f852262c4dbeb0bc231d/install-release.sh

SHA-256: `954666bb028ba8561b2218372b7db76ba051f8252b2db9195321e672263aab94`.

The upstream fixture is licensed under GPL-3.0; its unmodified license is included
in `Xray-install.LICENSE`. This third-party fixture retains its upstream license.

Tests load only its definitions and exercise the real argument parser. They never
call its installation entry point. Keep this fixture, the commit, and the checksum
in `core/handler.sh` synchronized when updating the upstream dependency.
