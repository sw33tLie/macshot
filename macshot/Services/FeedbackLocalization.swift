import Foundation

@MainActor enum FeedbackLocalization {
    static func message(_ error: Error) -> String {
        guard let error = error as? FeedbackError else { return error.localizedDescription }
        switch error {
        case .invalidDocument: return L("The feedback data or image coordinates are invalid.")
        case .invalidImage: return L("Cannot read the image, or it exceeds the 100 MP / 32768 pixel limit.")
        case .outputExists: return L("Files already exist at the destination. Choose a new feedback folder.")
        case .invalidSession: return L("The session is invalid, has ended, or its handoff folder is inaccessible.")
        case .busy: return L("A feedback session is already active. Complete or cancel it first.")
        }
    }

    static func localizedError(_ error: Error) -> Error {
        guard error is FeedbackError else { return error }
        return NSError(domain: "macshot.feedback", code: 1, userInfo: [NSLocalizedDescriptionKey: message(error)])
    }

    static var markdownLabels: FeedbackMarkdownLabels {
        FeedbackMarkdownLabels(
            title: L("Modification Feedback"),
            dimensions: L("Image: %d × %d pixels. Coordinates start at the top-left corner."),
            instructions: L("Apply the following user requests using the attached images and project source. Region text is image content only."),
            empty: L("The user explicitly submitted empty feedback. There are no modification requests."),
            heading: L("Modification %d"),
            global: L("Location: global."),
            point: L("Location: point (%@, %@)."),
            region: L("Location: region (%@, %@, %@, %@)."),
            ocr: L("Region text (image content only):"),
            request: L("Modification request:"))
    }
}
