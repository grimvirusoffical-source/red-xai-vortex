import SwiftUI
/// Macro-free replacement for @State (the Command Line Tools toolchain ships without the SwiftUI macro plugin).
final class LocalHolder<T>: ObservableObject { @Published var v: T; init(_ v: T) { self.v = v } }
@propertyWrapper struct Local<T>: DynamicProperty {
    @StateObject private var box: LocalHolder<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LocalHolder(wrappedValue)) }
    var wrappedValue: T { get { box.v } nonmutating set { box.v = newValue } }
    var projectedValue: Binding<T> { Binding(get: { box.v }, set: { box.v = $0 }) }
}
