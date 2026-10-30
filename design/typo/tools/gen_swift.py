import json, sys, math
d = json.load(open(sys.argv[1]))
def pts(name, arr):
    body = ", ".join(f"P({x}, {y})" for x, y in arr)
    return f"    static let {name}: [CGPoint] = [{body}]\n"
def extend(path, w):
    (x0,y0),(x1,y1) = path[0], path[1]
    l = math.hypot(x0-x1,y0-y1) or 1
    a = [x0+(x0-x1)/l*w*factor, y0+(y0-y1)/l*w*factor]
    (x0,y0),(x1,y1) = path[-1], path[-2]
    l = math.hypot(x0-x1,y0-y1) or 1
    b = [x0+(x0-x1)/l*w*factor, y0+(y0-y1)/l*w*factor]
    return [[round(a[0],1),round(a[1],1)]] + path + [[round(b[0],1),round(b[1],1)]]
w = d["strokeWidths"]["armL"]
factor = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
s = "import CoreGraphics\n\nprivate func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }\n\n/// Geometry traced from the Typo reference artwork, in a 2000 x 2000 design space.\nenum TypoReference {\n"
s += f"    static let strokeWidth: CGFloat = {w:.1f}\n"
for k in ['body','faceContour','eyeL','eyeR','bubble','armLShape','armRShape','mouthShape']:
    s += pts(k, d[k])
s += pts('armL', extend(d['armL'], w))
s += pts('armR', extend(d['armR'], w))
s += pts('mouth', d['mouth'])
s += "}\n"
open(sys.argv[2], 'w').write(s)
print("wrote", sys.argv[2])
