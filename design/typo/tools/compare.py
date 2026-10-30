import cv2, numpy as np, sys
ref = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE) < 128
out = cv2.imread(sys.argv[2], cv2.IMREAD_GRAYSCALE) < 128
inter, union = (ref & out).sum(), (ref | out).sum()
print(f"IoU overall: {inter/union:.4f}  ref-only px: {(ref&~out).sum()}  ours-only px: {(out&~ref).sum()}")
n, lab, st, _ = cv2.connectedComponentsWithStats(ref.astype(np.uint8), 8)
names = {}
for i in range(1, n):
    if st[i][4] < 1000: continue
    x, y, w, h, a = st[i]
    pad = 25
    r = ref[max(0,y-pad):y+h+pad, max(0,x-pad):x+w+pad]; o = out[max(0,y-pad):y+h+pad, max(0,x-pad):x+w+pad]
    print(f"  part at ({x},{y},{w},{h}): IoU {((r&o).sum()/max(1,(r|o).sum())):.4f}")
vis = np.full(ref.shape + (3,), 255, np.uint8)
vis[ref & out] = (40, 40, 40)
vis[ref & ~out] = (0, 0, 255)
vis[out & ~ref] = (255, 120, 0)
crop = vis[440:1360, 340:1820]
cv2.imwrite(sys.argv[3], crop)
k = np.ones((5,5),np.uint8)
refd = cv2.dilate(ref.astype(np.uint8),k).astype(bool); outd = cv2.dilate(out.astype(np.uint8),k).astype(bool)
print(f"pixels off by more than 2px: ref-only {(ref & ~outd).sum()}, ours-only {(out & ~refd).sum()}")
