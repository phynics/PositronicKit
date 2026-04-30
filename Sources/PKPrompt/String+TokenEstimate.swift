//
//  String+TokenEstimate.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 30.04.26.
//
import Foundation

package extension String {
    var estimatedTokenCount: Int {
        isEmpty ? 0 : Swift.max(1, count / 4)
    }
}
