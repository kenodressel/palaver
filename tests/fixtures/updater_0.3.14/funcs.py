# funcs.py NAMES...: the sources of these top-level functions and methods of the module on stdin, dedented
import ast
import sys
import textwrap
src = sys.stdin.read()
tree = ast.parse(src)
want = sys.argv[1:]
found = {}
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name in want and node.name not in found:
        found[node.name] = textwrap.dedent(" " * node.col_offset + ast.get_source_segment(src, node))
sys.stdout.write("\n\n".join(found[n] for n in want) + "\n")
