#if os(iOS)
import SwiftUI

enum DuoPosture {
    case compact, open, folded

    @available(iOS 27.1, *)
    init(_ status: DeviceHinge.Status?) {
        switch status {
        case .fullyOpen: self = .open
        case .partiallyOpen: self = .folded
        default: self = .compact
        }
    }
}

extension EnvironmentValues {
    @Entry var duoPosture = DuoPosture.compact
}

struct DuoPostureReader: ViewModifier {
    @State private var posture = DuoPosture.compact

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.environment(\.duoPosture, posture)
                .onHingeChange { _, context in posture = DuoPosture(context.hinge?.status) }
        } else { content }
    }
}

@available(iOS 27.1, *)
extension GeometryProxy {
    var duoColumnEdges: (left: CGFloat, rightStart: CGFloat) {
        let width = size.width
        let hinge = reservedRegions(kind: .division).map(\.frame).first {
            $0.height > $0.width && $0.midX > 0 && $0.midX < width
        }
        let insets = safeAreaInsets
        let middle = (width + insets.trailing - insets.leading) / 2
        let left = min(width, max(0, hinge?.minX ?? middle))
        let rightStart = min(width, max(left, hinge?.maxX ?? middle))
        return (left, rightStart)
    }
}

@available(iOS 27.1, *)
struct DuoLibraryPanes<Sidebar: View, Contents: View>: View {
    let folded: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let contents: () -> Contents

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let sidebarWidth = min(280, width * 0.32)
            let edges = folded ? geometry.duoColumnEdges : (left: sidebarWidth, rightStart: sidebarWidth)
            HStack(spacing: edges.rightStart - edges.left) {
                sidebar()
                    .frame(width: edges.left)
                    .overlay(alignment: .trailing) { Divider() }
                contents()
                    .frame(width: width - edges.rightStart)
            }
        }
    }
}

struct DuoFolderSidebar<Actions: View>: View {
    let title: String
    let folders: [String]
    let folder: String
    @Binding var expanded: Set<String>
    let select: (String) -> Void
    @ViewBuilder let actions: (String) -> Actions

    var body: some View {
        let children = Dictionary(grouping: folders, by: VaultLibrary.parent(of:))
        List {
            row("", depth: 0, hasChildren: false)
            if !folders.isEmpty {
                Section("Dossiers") {
                    ForEach(visibleFolders(children), id: \.self) { path in
                        row(path, depth: path.split(separator: "/").count - 1, hasChildren: children[path] != nil)
                            .contextMenu { actions(path) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: folder, initial: true) { _, path in
            var ancestor = VaultLibrary.parent(of: path)
            while !ancestor.isEmpty {
                expanded.insert(ancestor)
                ancestor = VaultLibrary.parent(of: ancestor)
            }
        }
    }

    private func visibleFolders(_ children: [String: [String]]) -> [String] {
        var paths: [String] = []
        var pending = Array((children[""] ?? []).reversed())
        while let path = pending.popLast() {
            paths.append(path)
            if expanded.contains(path), let nested = children[path] {
                pending.append(contentsOf: nested.reversed())
            }
        }
        return paths
    }

    private func row(_ path: String, depth: Int, hasChildren: Bool) -> some View {
        let name = path.split(separator: "/").last.map(String.init) ?? title
        return HStack(spacing: 4) {
            Button {
                select(path)
            } label: {
                Label(name, systemImage: path.isEmpty ? "lock.shield" : "folder")
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(folder == path ? .isSelected : [])
            if hasChildren {
                Button {
                    if !expanded.insert(path).inserted { expanded.remove(path) }
                } label: {
                    Image(systemName: expanded.contains(path) ? "chevron.down" : "chevron.right")
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel((expanded.contains(path) ? "Replier " : "Déplier ") + name)
            }
        }
        .padding(.leading, CGFloat(min(depth, 4)) * 10)
        .frame(minHeight: 44)
        .listRowBackground(folder == path ? Color.lockerTint.opacity(0.16) : Color.clear)
    }
}
#endif
