# gittle - a minimal git in Nim.  See docs/plan.md.

version       = "0.1.0"
author        = "Brian Zenowich"
description   = "A minimal git: on-disk compatible, ssh-only, one static binary"
license       = "MIT"
srcDir        = "src"
bin           = @["gittle"]

requires "nim >= 2.0.0"
