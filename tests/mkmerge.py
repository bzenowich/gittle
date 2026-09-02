"""Random three-way merge cases for `tests/oracle.sh`.

Writes `<dir>/c<N>/{base,ours,theirs}`, where `ours` and `theirs` are each a
few edits away from `base`.  The edits are deliberately small and repetitive
-- lines that recur, blank lines, lines that are only `}` -- because that is
what makes two independent changes *overlap*, which is the case the merge is
for.  A tenth of the files lose their final newline, which the record
comparison has to notice (see `diff.nim`'s note on the terminator).

Seeded, so a failure is reproducible: the same case number is the same three
files on every run.
"""

import os
import random
import sys

PIECES = ["new\n", "x\n", "}\n", "\n", "*/\n"]


def mutate(src, length, rng):
    out = list(src)
    for _ in range(rng.randint(0, 5)):
        if not out:
            out.insert(0, rng.choice(PIECES))
            continue
        k = rng.randrange(len(out))
        op = rng.choice("idr")
        if op == "i":
            out.insert(k, rng.choice(PIECES + ["%d\n" % rng.randint(0, 99)]))
        elif op == "d":
            del out[k]
        else:
            out[k] = rng.choice(PIECES + ["line %d\n" % rng.randint(0, length + 3)])
    return out


def main():
    root = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    rng = random.Random(7)
    os.makedirs(root, exist_ok=True)
    for case in range(count):
        length = rng.randint(0, 40)
        base = ["line %d\n" % i for i in range(length)]
        here = os.path.join(root, "c%d" % case)
        os.makedirs(here, exist_ok=True)
        for name, lines in (("base", base),
                            ("ours", mutate(base, length, rng)),
                            ("theirs", mutate(base, length, rng))):
            text = "".join(lines)
            if text and rng.random() < 0.1:
                text = text[:-1]
            with open(os.path.join(here, name), "w") as f:
                f.write(text)


main()
