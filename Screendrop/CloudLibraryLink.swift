//
//  CloudLibraryLink.swift
//  Screendrop
//

import AppKit

/// "My Library" opens the web library signed in as the owner: the app asks
/// the worker for a one-minute sign-in link with its upload token, so the
/// browser needs no OAuth.
enum CloudLibraryLink {
    static func open(path: String = "/library") {
        let creds = CloudCredentialStore.shared.snapshot()
        guard creds.isConfigured else {
            SettingsWindowController.show(tab: .cloud)
            return
        }
        let base = CloudUploader.normalizeWorkerURL(creds.workerURL)
        guard let plain = URL(string: base + path) else {
            SettingsWindowController.show(tab: .cloud)
            return
        }
        Task {
            // Without a code the page still opens; it asks the owner to sign in.
            NSWorkspace.shared.open(await signedInURL(base: base, token: creds.uploadToken, path: path) ?? plain)
        }
    }

    private static func signedInURL(base: String, token: String, path: String) async -> URL? {
        guard let url = URL(string: "\(base)/api/auth/handoff") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["redirect": path])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode([String: String].self, from: data),
              let link = body["url"]
        else { return nil }
        return URL(string: link)
    }
}
