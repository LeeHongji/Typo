import cv2, numpy as np, sys, json
img = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
blk = (img < 128).astype(np.uint8)
n, lab, stats, cent = cv2.connectedComponentsWithStats(blk, 8)
def comp_mask(i): return (lab == i).astype(np.uint8)
def contour(mask, eps=1.5, k=5):
    if k > 1: mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((k, k), np.uint8))
    cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cs, key=cv2.contourArea)
    a = cv2.approxPolyDP(c, eps, True)[:, 0, :]
    return a.tolist()
def zhang_suen(m):
    m = m.copy().astype(np.uint8)
    changed = True
    while changed:
        changed = False
        for step in (0, 1):
            p = np.pad(m, 1)
            P2,P3,P4,P5,P6,P7,P8,P9 = [p[0:-2,1:-1],p[0:-2,2:],p[1:-1,2:],p[2:,2:],p[2:,1:-1],p[2:,0:-2],p[1:-1,0:-2],p[0:-2,0:-2]]
            B = P2+P3+P4+P5+P6+P7+P8+P9
            seq = [P2,P3,P4,P5,P6,P7,P8,P9,P2]
            A = sum(((seq[k]==0)&(seq[k+1]==1)).astype(int) for k in range(8))
            if step == 0: c = (P2*P4*P6==0)&(P4*P6*P8==0)
            else: c = (P2*P4*P8==0)&(P2*P6*P8==0)
            rm = (m==1)&(B>=2)&(B<=6)&(A==1)&c
            if rm.any(): m[rm]=0; changed=True
    return m
def skeleton_path(mask, step=6):
    sk = zhang_suen(mask)
    ys, xs = np.nonzero(sk)
    pts = set(zip(xs.tolist(), ys.tolist()))
    def nb(p): return [(p[0]+dx,p[1]+dy) for dx in (-1,0,1) for dy in (-1,0,1) if (dx or dy) and (p[0]+dx,p[1]+dy) in pts]
    ends = [p for p in pts if len(nb(p)) == 1]
    start = ends[0] if ends else next(iter(pts))
    path, seen, cur = [start], {start}, start
    while True:
        nx = [q for q in nb(cur) if q not in seen]
        if not nx: break
        cur = nx[0]; seen.add(cur); path.append(cur)
    dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
    widths = [2*dist[y][x] for x, y in path]
    return [list(p) for p in path[::step]] + [list(path[-1])], float(np.median(widths))
out = {}
names = {}
for i in range(1, n):
    x, y, w, h, a = stats[i]
    if a < 1000: continue
    names[i] = (x, y, w, h, a)
order = sorted(names, key=lambda i: -names[i][4])
body, bubble = order[0], order[1]
rest = sorted(order[2:], key=lambda i: names[i][4], reverse=True)
eyes = sorted(rest[:2], key=lambda i: names[i][0])
arms = sorted(rest[2:4], key=lambda i: names[i][0])
mouth = rest[4]
out['body'] = contour(comp_mask(body), 1.2)
out['bubble'] = contour(comp_mask(bubble), 1.2)
out['eyeL'] = contour(comp_mask(eyes[0]), 0.8, 1)
out['eyeR'] = contour(comp_mask(eyes[1]), 0.8, 1)
out['armL'], wl = skeleton_path(comp_mask(arms[0]))
out['armR'], wr = skeleton_path(comp_mask(arms[1]))
out['mouth'], wm = skeleton_path(comp_mask(mouth), 3)
out['armLShape'] = contour(comp_mask(arms[0]), 0.6, 1)
out['armRShape'] = contour(comp_mask(arms[1]), 0.6, 1)
out['mouthShape'] = contour(comp_mask(mouth), 0.6, 1)
out['strokeWidths'] = {'armL': wl, 'armR': wr, 'mouth': wm}
wht = (img >= 128).astype(np.uint8)
n2, lab2, st2, c2 = cv2.connectedComponentsWithStats(wht, 8)
face = max([i for i in range(1, n2) if st2[i][4] < 1e6], key=lambda i: st2[i][4])
fm = (lab2 == face).astype(np.uint8)
cs, _ = cv2.findContours(fm, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
(cx, cy), (ma, mi), ang = cv2.fitEllipse(max(cs, key=cv2.contourArea))
out['faceEllipse'] = {'cx': cx, 'cy': cy, 'w': ma, 'h': mi, 'angle': ang}
out['faceContour'] = contour(fm, 1.2)
bm = comp_mask(bubble)
cs, _ = cv2.findContours(bm, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
(bx, by), (bw, bh), bang = cv2.fitEllipse(max(cs, key=cv2.contourArea))
out['bubbleEllipse'] = {'cx': bx, 'cy': by, 'w': bw, 'h': bh, 'angle': bang}
for k in ['body','bubble','eyeL','eyeR','faceContour']: print(k, 'points', len(out[k]))
print('arms/mouth widths', out['strokeWidths'])
print('face ellipse', {k: round(v,1) for k,v in out['faceEllipse'].items()})
print('bubble ellipse', {k: round(v,1) for k,v in out['bubbleEllipse'].items()})
print('armL path', out['armL'][::6]); print('armR path', out['armR'][::6]); print('mouth', out['mouth'][::4])
json.dump(out, open(sys.argv[2], 'w'))
