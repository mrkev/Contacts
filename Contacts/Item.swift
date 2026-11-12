//
//  Item.swift
//  Contacts
//
//  Created by Kevin on 12/11/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
