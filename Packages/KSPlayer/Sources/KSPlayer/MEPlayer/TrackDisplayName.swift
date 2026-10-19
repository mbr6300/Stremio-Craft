//
//  TrackDisplayName.swift
//  KSPlayer – Ergänzung für Stremio Craft
//
//  Lesbare Namen für das Tonspur-Menü: zuerst die Sprache, dann das Tonformat
//  (z. B. „Deutsch · Dolby TrueHD Atmos · 7.1“) statt der technischen Beschreibung.
//

import FFmpegKit
import Foundation
import Libavformat

public extension MediaPlayerTrack {
    /// Bezeichnung für Auswahlmenüs; fällt für Nicht-FFmpeg-Spuren auf `description` zurück.
    var menuTitle: String {
        (self as? FFmpegAssetTrack)?.readableAudioTitle ?? description
    }
}

extension FFmpegAssetTrack {
    var readableAudioTitle: String {
        guard mediaType == .audio else { return name }
        var parts = [languageName ?? "Unbekannte Sprache", formatTitle]
        if let channels = channelTitle { parts.append(channels) }
        if let purpose = purposeTitle { parts.append(purpose) }
        return parts.joined(separator: " · ")
    }

    /// Titel aus den Metadaten der Datei (z. B. „German DTS-HD MA 5.1“), falls vorhanden.
    private var metadataTitle: String? {
        name.isEmpty || name == languageCode || name == codecName ? nil : name
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
    private var purposeTitle: String? {
        guard let title = metadataTitle?.lowercased() else { return nil }
        if title.contains("comment") || title.contains("kommentar") { return "Kommentar" }
        if title.contains("descri") || title.contains("audiodeskription") || title.contains("hörfilm") {
            return "Audiodeskription"
        }
        return nil
    }
}
