import Foundation

public enum AuthFolderCleanupInspector {
    private static let ignorableMetadataFiles: Set<String> = [
        ".DS_Store",
    ]

    public static func canSafelyDeleteDuplicateFolder(
        folderURL: URL,
        authFileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return false
        }

        var sawAuthFile = false

        for item in contents {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                return false
            }

            if item.standardizedFileURL == authFileURL.standardizedFileURL {
                sawAuthFile = true
                continue
            }

            if ignorableMetadataFiles.contains(item.lastPathComponent) {
                continue
            }

            return false
        }

        return sawAuthFile
    }
}
