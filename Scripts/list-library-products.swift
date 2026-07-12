#!/usr/bin/env swift

import Foundation

struct PackageDescription: Decodable {
    let products: [Product]
}

struct Product: Decodable {
    let name: String
    let type: ProductType
}

struct ProductType: Decodable {
    let library: [String]?
}

let data = FileHandle.standardInput.readDataToEndOfFile()
let description = try JSONDecoder().decode(PackageDescription.self, from: data)

for product in description.products where product.type.library != nil {
    print(product.name)
}
