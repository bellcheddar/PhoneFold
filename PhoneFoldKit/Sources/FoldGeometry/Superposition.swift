import Foundation
import simd

/// The rigid transform that best maps one point set onto another, and how well it fits.
public struct Superposition: Sendable, Equatable {
    /// Rotation to apply to the mobile set after centring it on its own centroid.
    public let rotation: simd_float3x3
    /// Centroid of the mobile set, subtracted before rotating.
    public let mobileCentroid: SIMD3<Float>
    /// Centroid of the reference set, added after rotating.
    public let referenceCentroid: SIMD3<Float>
    /// Root mean square deviation after superposition, in angstroms.
    public let rmsd: Float

    /// Map a point from the mobile frame into the reference frame.
    @inlinable
    public func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
        rotation * (point - mobileCentroid) + referenceCentroid
    }

    @inlinable
    public func apply(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        points.map(apply)
    }
}

public enum Kabsch {

    /// Optimal rigid superposition of `mobile` onto `reference`, by Horn's quaternion method
    /// (J. Opt. Soc. Am. A 1987, 4(4):629).
    ///
    /// Horn rather than the more familiar SVD formulation for one specific reason: **the
    /// quaternion construction can only produce a proper rotation.** The SVD form has to
    /// detect a negative determinant and flip the third singular vector, and getting that
    /// wrong silently mirrors the molecule, which looks almost right and is completely
    /// wrong. There is no such case to get wrong here.
    ///
    /// Arithmetic is done in `Double`. The correlation matrix accumulates a sum over every
    /// residue, and in `Float` that loses precision badly for a 300-residue protein whose
    /// coordinates run to tens of angstroms.
    ///
    /// Returns `nil` for empty or mismatched inputs rather than trapping: a trajectory with
    /// a bad frame should degrade, not crash the audio thread.
    public static func superpose(mobile: [SIMD3<Float>],
                                 onto reference: [SIMD3<Float>]) -> Superposition? {
        guard mobile.count == reference.count, mobile.count >= 3 else { return nil }

        let n = Double(mobile.count)
        var mobileCentre = SIMD3<Double>.zero
        var referenceCentre = SIMD3<Double>.zero
        for i in mobile.indices {
            mobileCentre += SIMD3<Double>(mobile[i])
            referenceCentre += SIMD3<Double>(reference[i])
        }
        mobileCentre /= n
        referenceCentre /= n

        // Correlation matrix S[a][b] = sum_i p_i[a] * q_i[b], over centred coordinates.
        var s = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var mobileNorm = 0.0
        var referenceNorm = 0.0
        for i in mobile.indices {
            let p = SIMD3<Double>(mobile[i]) - mobileCentre
            let q = SIMD3<Double>(reference[i]) - referenceCentre
            mobileNorm += simd_length_squared(p)
            referenceNorm += simd_length_squared(q)
            for a in 0..<3 {
                for b in 0..<3 {
                    s[a][b] += p[a] * q[b]
                }
            }
        }

        // Horn's symmetric 4x4. Its largest eigenvector is the optimal rotation quaternion.
        let (sxx, sxy, sxz) = (s[0][0], s[0][1], s[0][2])
        let (syx, syy, syz) = (s[1][0], s[1][1], s[1][2])
        let (szx, szy, szz) = (s[2][0], s[2][1], s[2][2])
        let matrix: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]

        guard let (largestEigenvalue, quaternion) = largestEigenpair(of: matrix) else {
            return nil
        }

        // RMSD without applying the transform: |P|^2 + |Q|^2 - 2*lambda_max, all over n.
        // Cheaper and more accurate than rotating every point and measuring.
        let residual = max(0, mobileNorm + referenceNorm - 2 * largestEigenvalue)
        let rmsd = Float((residual / n).squareRoot())

        return Superposition(rotation: rotationMatrix(from: quaternion),
                             mobileCentroid: SIMD3<Float>(mobileCentre),
                             referenceCentroid: SIMD3<Float>(referenceCentre),
                             rmsd: rmsd)
    }

    /// RMSD after optimal superposition, without keeping the transform.
    public static func rmsd(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float? {
        superpose(mobile: a, onto: b)?.rmsd
    }

    // MARK: - 4x4 symmetric eigenproblem

    /// Largest eigenvalue and its eigenvector, by cyclic Jacobi rotations.
    ///
    /// A 4x4 symmetric matrix converges in a handful of sweeps and Jacobi is unconditionally
    /// stable, which matters because this runs once per frame for the whole trajectory.
    static func largestEigenpair(of input: [[Double]]) -> (Double, SIMD4<Double>)? {
        var a = input
        var v = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<4 { v[i][i] = 1 }

        for _ in 0..<64 {
            // Largest off-diagonal magnitude decides both convergence and the pivot.
            var (p, q, offDiagonal) = (0, 1, 0.0)
            for i in 0..<3 {
                for j in (i + 1)..<4 where abs(a[i][j]) > offDiagonal {
                    (p, q, offDiagonal) = (i, j, abs(a[i][j]))
                }
            }
            if offDiagonal < 1e-14 { break }

            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let sign = theta >= 0 ? 1.0 : -1.0
            let t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            for k in 0..<4 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<4 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<4 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }

        var best = 0
        for i in 1..<4 where a[i][i] > a[best][best] { best = i }
        let eigenvalue = a[best][best]
        var vector = SIMD4<Double>(v[0][best], v[1][best], v[2][best], v[3][best])
        let norm = simd_length(vector)
        guard norm > 0, norm.isFinite else { return nil }
        vector /= norm
        return (eigenvalue, vector)
    }

    /// Unit quaternion (w, x, y, z) to a rotation matrix.
    static func rotationMatrix(from q: SIMD4<Double>) -> simd_float3x3 {
        let (w, x, y, z) = (q[0], q[1], q[2], q[3])
        let (ww, xx, yy, zz) = (w * w, x * x, y * y, z * z)
        let (wx, wy, wz) = (w * x, w * y, w * z)
        let (xy, xz, yz) = (x * y, x * z, y * z)
        // Columns, because simd_float3x3 is column-major.
        return simd_float3x3(
            SIMD3<Float>(Float(ww + xx - yy - zz), Float(2 * (xy + wz)), Float(2 * (xz - wy))),
            SIMD3<Float>(Float(2 * (xy - wz)), Float(ww - xx + yy - zz), Float(2 * (yz + wx))),
            SIMD3<Float>(Float(2 * (xz + wy)), Float(2 * (yz - wx)), Float(ww - xx - yy + zz)))
    }
}
