import SwiftUI
import AVKit

// 按 artifact.kind 渲染产物：脚本(md)/音频/视频/图片/数据(json)/目录。
// 碎片时间审看：读稿、听音、看片、钻采集目录。

struct ArtifactRow: View {
    let artifact: NofArtifact
    let client: NofClient

    private var icon: String {
        switch artifact.kind {
        case "script", "text": return "doc.text"
        case "audio": return "waveform"
        case "video": return "play.rectangle"
        case "image": return "photo"
        case "data": return "curlybraces"
        case "dir": return "folder"
        default: return "doc"
        }
    }

    var body: some View {
        NavigationLink {
            ArtifactViewer(artifact: artifact, client: client)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.label).font(.body)
                    Text(artifact.kind).font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
            }
        }
    }
}

struct ArtifactViewer: View {
    let artifact: NofArtifact
    let client: NofClient

    var body: some View {
        Group {
            switch artifact.kind {
            case "image":
                if let url = client.absoluteURL(artifact.url) {
                    ScrollView([.horizontal, .vertical]) { AsyncImage(url: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { ProgressView() } }
                }
            case "audio":
                MediaPlayerView(url: client.absoluteURL(artifact.url), audioOnly: true)
            case "video":
                MediaPlayerView(url: client.absoluteURL(artifact.url), audioOnly: false)
            case "dir":
                DirBrowserView(dirURL: artifact.url, title: artifact.label, client: client)
            default:  // script / text / data / file
                RemoteTextView(url: client.absoluteURL(artifact.url),
                               markdown: artifact.kind == "script")
            }
        }
        .navigationTitle(artifact.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 音视频播放：AVPlayer，url 支持 Range，可拖进度。
struct MediaPlayerView: View {
    let url: URL?
    let audioOnly: Bool

    var body: some View {
        if let url {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(maxHeight: audioOnly ? 120 : .infinity)
                .padding(audioOnly ? .horizontal : [])
        } else {
            ContentUnavailableView("无法播放", systemImage: "exclamationmark.triangle")
        }
    }
}

/// 拉远端文本渲染：script 走 Markdown，其余等宽纯文本。
struct RemoteTextView: View {
    let url: URL?
    let markdown: Bool

    @State private var text: String = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding()
            } else if let error {
                ContentUnavailableView("加载失败", systemImage: "wifi.slash", description: Text(error))
            } else if markdown {
                Text(attributed).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            } else {
                Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
        .task { await load() }
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func load() async {
        guard let url else { loading = false; error = "地址非法"; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            text = String(data: data, encoding: .utf8) ?? ""
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// 目录浏览：列条目，文件钻进 viewer，子目录继续钻。
struct DirBrowserView: View {
    let dirURL: String
    let title: String
    let client: NofClient

    @State private var entries: [DirEntry] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func entryRow(_ entry: DirEntry) -> some View {
        if let url = entry.url {
            let art = NofArtifact(label: entry.name, kind: entry.kind, url: url, path: nil)
            ArtifactRow(artifact: art, client: client)
        } else {
            Label(entry.name, systemImage: entry.is_dir ? "folder" : "doc")
        }
    }

    private func load() async {
        do {
            entries = try await client.dirListing(dirURL).entries
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
