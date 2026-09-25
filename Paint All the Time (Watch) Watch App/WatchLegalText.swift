// Bundled for offline reading on Apple Watch.
// Privacy: docs/PRIVACY.md
// Keep the source paragraphs and catalog translations aligned with the privacy policy.
enum WatchLegalText {
    static var privacy: [String] { privacyKeys.map { L10n.text($0) } }

    private static let privacyKeys: [String] = [
        "Paint Anytime Privacy Policy",
        "Last updated: September 24, 2026",
        "Paint Anytime is developed by Denis Kolchev. This policy covers the official Apple Watch app and its iPhone companion, where available. Features may vary by app version.",
        "Drawing and settings data",
        "Paint Anytime does not require an account. Drawings saved to the gallery, editable drawing data, and preferences such as language and tool settings are stored locally on your device. The app does not upload your drawings or preferences to a developer-operated server.",
        "The app contains no advertising, third-party analytics, or tracking SDKs, and does not send usage analytics to the developer. Apple may separately process App Store, purchase, or diagnostic information under its own privacy settings and policies.",
        "Sharing and saving to Photos",
        "When you choose to share a drawing, the selected image is passed to the app or service you choose in the system sharing interface. That service handles the image under its own terms and privacy policy. The developer does not receive a copy unless you send one to the developer yourself.",
        "Where the iPhone photo-transfer feature is available, drawings you choose to transfer are sent from your Apple Watch to the companion iPhone app using Apple's WatchConnectivity framework. The iPhone app requests permission to add images to Photos; it does not request access to read your existing photo library. Received images are kept in a local queue until successfully saved to Photos, after which the app removes the queued copy. If permission is denied or saving fails, images can remain queued locally.",
        "Your device backups and iCloud Photos settings may cause Apple to back up app data or synchronize exported images. These services are controlled by your Apple settings, not by a Paint Anytime server.",
        "Contacting support",
        "If you email paintanytime.app@gmail.com, the developer receives your email address and the message and attachments you choose to send. The in-app bug-report action opens an email draft with a subject; it does not automatically attach drawings or diagnostic logs.",
        "Support messages are used to respond to your request and investigate problems. They are processed by the email providers involved in delivery, including Gmail for the support inbox. Avoid sending sensitive information that is not needed for your request. Messages are retained for as long as reasonably needed to handle the request and related follow-up, or meet applicable legal obligations. You may request deletion using the same email address, subject to those obligations.",
        "Retention and your choices",
        "You can delete saved drawings from the app's gallery. Deleting a drawing there does not delete copies already exported to Photos, shared with others, or included in backups. Manage those copies in the respective apps and backup services.",
        "You can revoke Photos permission in iPhone Settings. Deleting the app (rather than offloading it) removes its local app data from that device, including any local transfer queue. Backups and exported copies must be managed separately. The developer cannot access or delete drawings stored only on your devices.",
        "External links",
        "Opening links to this policy, the source repository, or Apple's license agreement connects you to GitHub or Apple. Those sites may process technical information such as your IP address under their own privacy policies:",
        "- GitHub Privacy Statement (https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)\n- Apple Privacy Policy (https://www.apple.com/legal/privacy/)\n- Google Privacy Policy (https://policies.google.com/privacy)",
        "Changes and contact",
        "This policy will be updated if the app's data practices change. The date above identifies the latest revision.",
        "For privacy questions or requests, contact Denis Kolchev at paintanytime.app@gmail.com (mailto:paintanytime.app@gmail.com).",
    ]
}
