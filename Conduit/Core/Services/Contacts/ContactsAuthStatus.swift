//
//  ContactsAuthStatus.swift
//  Conduit
//
//  Authorization state for the system-contact mirror, mapped from
//  `CNAuthorizationStatus` in the real service.
//

import Foundation

enum ContactsAuthStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case limited
}
