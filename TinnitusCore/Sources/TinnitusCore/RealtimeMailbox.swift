import Foundation
import os

/// Hands values from the main thread to the audio thread without the audio thread ever waiting,
/// allocating, or freeing memory.
///
/// The main thread posts a value. The audio thread swaps it for the value it was using, and the old
/// value waits in a "retired" slot until the main thread's next post releases it there. Freeing
/// memory on the audio thread can take a lock inside the allocator and cause a dropout.
public final class RealtimeMailbox<Value>: @unchecked Sendable {
    private struct Slots {
        var pending: Value?
        var retired: Value?
    }

    private let slots = OSAllocatedUnfairLock<Slots>(uncheckedState: Slots())

    public init() {}

    /// Main thread: offers a new value. Any value it replaces, and any retired value, is released here.
    public func post(_ value: Value) {
        let released = slots.withLockUnchecked { slots -> (Value?, Value?) in
            let old = (slots.pending, slots.retired)
            slots.pending = value
            slots.retired = nil
            return old
        }
        _ = released
    }

    /// Main thread: releases a retired value without posting a new one.
    public func collectGarbage() {
        let released = slots.withLockUnchecked { slots -> Value? in
            defer { slots.retired = nil }
            return slots.retired
        }
        _ = released
    }

    /// Audio thread: if a new value is waiting, swaps it into `current` and keeps the old one for the
    /// main thread to release. Returns false, without waiting, if nothing is new or the lock is busy.
    public func exchange(_ current: inout Value) -> Bool {
        slots.withLockIfAvailableUnchecked { slots -> Bool in
            guard slots.retired == nil, let next = slots.pending else { return false }
            slots.pending = nil
            slots.retired = current
            current = next
            return true
        } ?? false
    }
}
