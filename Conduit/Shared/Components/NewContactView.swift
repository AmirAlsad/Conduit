//
//  NewContactView.swift
//  Conduit
//
//  SwiftUI wrapper over the system "New Contact" card
//  (`CNContactViewController(forNewContact:)`). Presenting it does NOT require
//  Contacts permission — the user saves the contact through system UI, so the app
//  never touches `CNContactStore`. Adding an agent here makes its name and photo
//  appear on the call / lock / CarPlay screens (the synthetic email links the
//  contact to the call handle).
//
//  A view-layer adapter for a UIKit system controller, so it lives with the other
//  shared components rather than behind a service protocol — there is no store
//  round-trip left to fake.
//

import ContactsUI
import SwiftUI

struct NewContactView: UIViewControllerRepresentable {
    let info: AgentMirrorInfo
    /// Identifier of the saved contact, or `nil` if the user cancelled.
    let onComplete: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = AgentContactBuilder.makeContact(from: info)
        let controller = CNContactViewController(forNewContact: contact)
        controller.delegate = context.coordinator
        // The new-contact card's Cancel / Done buttons live in a navigation bar.
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        private let onComplete: (String?) -> Void

        init(onComplete: @escaping (String?) -> Void) {
            self.onComplete = onComplete
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onComplete(contact?.identifier)
        }
    }
}
