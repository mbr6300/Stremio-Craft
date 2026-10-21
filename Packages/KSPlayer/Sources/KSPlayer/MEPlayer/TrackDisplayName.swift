//
//  TrackDisplayName.swift
//  KSPlayer – Ergänzung für Stremio Craft
//
//  Lesbare Namen für Ton- und Untertitel-Menüs: zuerst die Sprache, dann die Art
//  (z. B. „Deutsch · Dolby TrueHD Atmos · 7.1“ oder „Englisch · Für Hörgeschädigte“)
//  statt Sprachkürzeln und technischer Beschreibung.
//

import FFmpegKit
import Foundation
import Libavformat

public extension MediaPlayerTrack {
    /// Bezeichnung für Auswahlmenüs; fällt für Nicht-FFmpeg-Spuren auf `description` zurück.
    var menuTitle: String {
        guard let track = self as? FFmpegAssetTrack else { return description }
        return track.mediaType == .subtitle ? track.readableSubtitleTitle : track.readableAudioTitle
    }
}

/// Bezeichnung einer Untertitel-Quelle (eingebettet oder extern) für das Menü.
public func subtitleMenuTitle(_ info: any SubtitleInfo) -> String {
    (info as? FFmpegAssetTrack)?.readableSubtitleTitle ?? info.name
}

/// Index der bevorzugten Tonspur in einer Sprache (z. B. „en“): normale Spur vor Kommentar
/// oder Audiodeskription. `nil`, wenn es keine Spur in dieser Sprache gibt.
public func preferredAudioIndex(_ tracks: [MediaPlayerTrack], language: String) -> Int? {
    let candidates = tracks.indices.filter { (tracks[$0] as? FFmpegAssetTrack)?.matches(language: language) == true }
    return candidates.first { (tracks[$0] as? FFmpegAssetTrack)?.purposeTitle == nil } ?? candidates.first
}

/// Bevorzugte Untertitel in einer Sprache: vollständige vor „nur fremdsprachige Stellen“,
/// normale vor solchen für Hörgeschädigte; Kommentar-Untertitel zuletzt.
public func preferredSubtitle(_ infos: [any SubtitleInfo], language: String) -> (any SubtitleInfo)? {
    let tracks = infos.compactMap { $0 as? FFmpegAssetTrack }.filter { $0.matches(language: language) }
    func rank(_ track: FFmpegAssetTrack) -> Int {
        let title = track.readableSubtitleTitle
        if title.contains("Kommentar") { return 3 }
        if title.contains("Nur ") { return 2 }
        return title.contains("Hörgeschädigte") ? 1 : 0
    }
    return tracks.min { rank($0) < rank($1) }
}

extension FFmpegAssetTrack {
    /// Sprache anhand des Codes (ISO 639-1/-2, z. B. „en“/„eng“) oder notfalls des Titels.
    func matches(language: String) -> Bool {
        let english = Locale(identifier: "en_US_POSIX")
        guard let name = english.localizedString(forLanguageCode: language)?.lowercased() else { return false }
        if let code = languageCode?.lowercased(), !code.isEmpty, code != "und" {
            // ISO 639-2 („eng“) und 639-1 („en“) über den Sprachnamen vergleichen.
            return code == language || english.localizedString(forLanguageCode: code)?.lowercased() == name
        }
        return title?.lowercased().contains(name) == true
    }

    var readableAudioTitle: String {
        guard mediaType == .audio else { return name }
        var parts = [languageName ?? metadataTitle ?? "Unbekannte Sprache", formatTitle]
        if let channels = channelTitle { parts.append(channels) }
        if let purpose = purposeTitle { parts.append(purpose) }
        return parts.joined(separator: " · ")
    }

    var readableSubtitleTitle: String {
        var parts = [languageName ?? metadataTitle ?? "Unbekannte Sprache"]
        let title = metadataTitle?.lowercased() ?? ""
        func mentions(_ words: String...) -> Bool { words.contains { title.contains($0) } }
        if isForced || mentions("forced", "erzwungen", "foreign") {
            parts.append("Nur fremdsprachige Stellen")
        } else if mentions("signs", "songs", "schilder") {
            parts.append("Nur Schilder & Lieder")
        }
        if isHearingImpaired || mentions("sdh", "hearing", "hörgeschädigt", "gehörlos") || title.split(separator: " ").contains("cc") {
            parts.append("Für Hörgeschädigte")
        }
        if mentions("comment", "kommentar") { parts.append("Kommentar") }
        return parts.joined(separator: " · ")
    }

    /// Titel aus den Metadaten der Datei (z. B. „German DTS-HD MA 5.1“), falls vorhanden.
    private var metadataTitle: String? {
        guard let title, !title.isEmpty, title != languageCode, title != codecName else { return nil }
        return title
    }

    private var languageName: String? {
        guard let code = languageCode?.lowercased(), !code.isEmpty else { return nil }
        // Dateien nutzen oft bibliografische ISO-639-2-Codes, die `Locale` nicht kennt.
        let bibliographic = [
            "ger": "de", "fre": "fr", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el",
            "per": "fa", "rum": "ro", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu",
            "bur": "my", "geo": "ka", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms",
            "tib": "bo", "wel": "cy", "scc": "sr", "scr": "hr"
        ]
        let normalized = bibliographic[code] ?? code
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? "de")
        guard let name = locale.localizedString(forLanguageCode: normalized), name.lowercased() != normalized else {
            return code.uppercased()
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var formatTitle: String {
        // FFmpeg-Profile: Atmos 30 (E-AC-3/TrueHD), DTS 50 HRA, 60 MA, 61/62 DTS:X, 70 Express.
        let profile = codecpar.profile
        let hasAtmosHint = metadataTitle?.localizedCaseInsensitiveContains("atmos") == true
        switch codecpar.codec_id {
        case AV_CODEC_ID_TRUEHD:
            return profile == 30 || hasAtmosHint ? "Dolby TrueHD Atmos" : "Dolby TrueHD"
        case AV_CODEC_ID_EAC3:
            return profile == 30 || hasAtmosHint ? "Dolby Digital Plus Atmos" : "Dolby Digital Plus"
        case AV_CODEC_ID_AC3:
            return "Dolby Digital"
        case AV_CODEC_ID_DTS:
            switch profile {
            case 61, 62: return "DTS:X"
            case 60: return "DTS-HD Master Audio"
            case 50: return "DTS-HD High Resolution"
            case 70: return "DTS Express"
            default: return "DTS"
            }
        case AV_CODEC_ID_AAC: return "AAC"
        case AV_CODEC_ID_FLAC: return "FLAC"
        case AV_CODEC_ID_OPUS: return "Opus"
        case AV_CODEC_ID_MP3: return "MP3"
        case AV_CODEC_ID_VORBIS: return "Vorbis"
        default:
            let base = codecName.components(separatedBy: " (").first ?? codecName
            return base.hasPrefix("pcm") ? "PCM" : base.uppercased()
        }
    }

    private var channelTitle: String? {
        switch codecpar.ch_layout.nb_channels {
        case 0: return nil
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        case let count: return "\(count) Kanäle"
        }
    }

    /// Besondere Spuren erkennbar machen (Kommentar, Audiodeskription).
    var purposeTitle: String? {
        guard let title = metadataTitle?.lowercased() else { return nil }
        if title.contains("comment") || title.contains("kommentar") { return "Kommentar" }
        if title.contains("descri") || title.contains("audiodeskription") || title.contains("hörfilm") {
            return "Audiodeskription"
        }
        return nil
    }
}
