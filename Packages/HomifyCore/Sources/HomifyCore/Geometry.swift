import Foundation

/// 2D affine transform using the same convention as CGAffineTransform:
/// x' = a·x + c·y + tx, y' = b·x + d·y + ty.
public struct Affine: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ x: Double, _ y: Double) -> Affine { Affine(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public static func scale(_ s: Double) -> Affine { Affine(a: s, b: 0, c: 0, d: s, tx: 0, ty: 0) }
    /// Counter-clockwise rotation in a y-up coordinate system.
    public static func rotation(radians r: Double) -> Affine {
        Affine(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0)
    }

    /// `self` applied first, then `t` (same as CGAffineTransform.concatenating).
    public func concatenating(_ t: Affine) -> Affine {
        Affine(a: a * t.a + b * t.c,
               b: a * t.b + b * t.d,
               c: c * t.a + d * t.c,
               d: c * t.b + d * t.d,
               tx: tx * t.a + ty * t.c + t.tx,
               ty: tx * t.b + ty * t.d + t.ty)
    }

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }
}

public enum LayerGeometry {
    /// Number of clockwise quarter turns encoded in a preferredTransform.
    public static func quarterTurns(_ m: [Double]) -> Int {
        guard m.count >= 4 else { return 0 }
        let angle = atan2(m[1], m[0]) // radians, CG's y-down space → clockwise visually
        var q = Int((angle / (.pi / 2)).rounded()) % 4
        if q < 0 { q += 4 }
        return q
    }

    /// Aspect-fit scale of a `w×h` picture into a `W×H` canvas.
    public static func fitScale(sourceWidth w: Double, sourceHeight h: Double, canvasWidth W: Double, canvasHeight H: Double) -> Double {
        guard w > 0, h > 0 else { return 1 }
        return min(W / w, H / h)
    }

    /// Transform that places an upright source picture (origin at its
    /// bottom-left, y-up — Core Image convention) into the canvas.
    ///
    /// Order: centre on origin → fit × user scale → rotate (clockwise on
    /// screen) → move to canvas centre + user offset (+y = down on screen).
    public static func layerTransform(sourceWidth w: Double, sourceHeight h: Double,
                                      canvasWidth W: Double, canvasHeight H: Double,
                                      transform v: TransformValue) -> Affine {
        let s = fitScale(sourceWidth: w, sourceHeight: h, canvasWidth: W, canvasHeight: H) * v.scale
        return Affine.translation(-w / 2, -h / 2)
            .concatenating(.scale(s))
            .concatenating(.rotation(radians: -v.rotation * .pi / 180))
            .concatenating(.translation(W / 2 + v.positionX * W, H / 2 - v.positionY * H))
    }
}
