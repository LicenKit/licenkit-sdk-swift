import Foundation

actor OperationCoordinator {
    private typealias ValidationTask = Task<LicenKitResult<EntitlementSnapshot>, Never>
    private var tail: Task<Void, Never>?
    private var validationGeneration = 0
    private var activeValidation: (generation: Int, task: ValidationTask)?

    func validate(
        _ operation: @Sendable @escaping () async -> LicenKitResult<EntitlementSnapshot>
    ) async -> LicenKitResult<EntitlementSnapshot> {
        if let activeValidation { return await activeValidation.task.value }

        let previous = tail
        validationGeneration += 1
        let generation = validationGeneration
        let task = Task {
            if let previous { await previous.value }
            return await operation()
        }
        activeValidation = (generation, task)
        tail = Task { _ = await task.value }
        let result = await task.value
        if activeValidation?.generation == generation { activeValidation = nil }
        return result
    }

    func perform<Value: Sendable>(
        _ operation: @Sendable @escaping () async -> Value
    ) async -> Value {
        // Calls that arrive after this explicit mutation must queue behind it instead
        // of joining an older validation that is still completing.
        activeValidation = nil
        let previous = tail
        let task = Task {
            if let previous { await previous.value }
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
