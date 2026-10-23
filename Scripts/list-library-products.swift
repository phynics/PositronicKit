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
let products: [Product]
do {
    products = try JSONDecoder().decode(PackageDescription.self, from: data).products
} catch {
    fputs("list-library-products: could not decode package description: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

for product in products where product.type.library != nil {
    print(product.name)
}
