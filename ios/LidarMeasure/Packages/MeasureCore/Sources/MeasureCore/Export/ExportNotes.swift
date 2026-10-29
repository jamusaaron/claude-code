import Foundation

/// Plain-text notes shipped inside every export, so the file explains itself after it leaves the app.
public enum ExportNotes {
    public static func readme(format: String, baseName: String = "model") -> String {
        """
        LiDAR Measure scan (\(format))

        Units: metres. Up axis: +Y. The origin is the bottom centre of the scan, so the model
        rests on the floor when placed in AR.

        Geometry comes from the phone's LiDAR scene reconstruction (roughly 1–3 cm detail).
        Fine features, sharp edges and thin parts are smoothed or missing. It is a shape
        estimate, not CAD or survey data.

        Each triangle is textured from the single camera view that saw it best, checked
        against that view's LiDAR depth. Expect lighting seams between views. Neutral grey
        areas were never seen clearly by the camera.

        OBJ: keep \(baseName).obj, \(baseName).mtl and texture.jpg in the same folder.
        USDZ and GLB are self-contained.
        """
    }
}
