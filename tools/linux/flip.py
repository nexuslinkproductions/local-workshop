import sys
from PIL import Image, ImageOps

# flip.py <in.png> <out.png>: vertical flip. The OpenGL readback of the offscreen
# render is bottom-up, so v5-shot.sh flips it to upright.
im = Image.open(sys.argv[1]).convert("RGB")
ImageOps.flip(im).save(sys.argv[2])
