import Foundation

/// Turns archive paths into safe relative paths, so that a malicious archive
/// cannot write outside the destination folder ("zip slip").
public enum PathSanitizer {
    /// Returns the relative path to use for `path`, or nil when nothing should be written.
    public static func relativePath(for path: String, options: ExtractionOptions) -> String? {
        var components = safeComponents(of: path)

        if let prefix = options.stripPrefix, !prefix.isEmpty {
            let prefixComponents = safeComponents(of: prefix)
            guard components.count > prefixComponents.count,
                  Array(components.prefix(prefixComponents.count)) == prefixComponents else {
                return nil
            }
            components.removeFirst(prefixComponents.count)
        }

        if options.flattenPaths, let last = components.last {
            components = [last]
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// Splits a path and drops empty, `.` and `..` components as well as
    /// Windows drive prefixes such as `C:`.
    public static func safeComponents(of path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { component in
                if component == "." || component == ".." { return false }
                if component.count == 2, component.hasSuffix(":"), component.first?.isLetter == true { return false }
                return true
            }
    }
}
