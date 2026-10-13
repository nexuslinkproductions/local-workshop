#!/bin/sh
# count_first_request.sh <profile> [model-id]   e.g. chief-v3-t5 ; "chief ornith-chief" for the live profile (read only, scratch copy)
# CPU only. The python is the Hermes tools python plus the Hermes environment's site-packages (the venv/bin/python shims break
# "python script.py"), imports happen through -c.
PYBIN=$(ls -d "$HOME"/.hermes/tools/python-3.14.7*linux-x64/bin/python3 | head -1)
SP=$(ls -d "$HOME"/.hermes/installs/*/environments/*/venv/lib/python3.14/site-packages | head -1)
exec "$PYBIN" -c "
import sys, runpy
sys.path[:0] = ['$SP']
import yaml, jinja2
sys.argv = ['count_first_request.py'] + sys.argv[1:]
runpy.run_path('$(cd "$(dirname "$0")" && pwd)/count_first_request.py', run_name='__main__')" "$@" 2> /dev/null
