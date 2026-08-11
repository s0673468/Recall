package com.german.health_anki_flutter

/**
 * Tracks the one network whose validated transition has already triggered a
 * replay. Losing validation clears that marker even when Android does not emit
 * onLost, so the same network can trigger again after Internet access returns.
 */
internal class ValidatedNetworkTransition<T> {
    private var current: T? = null

    fun onCapabilitiesChanged(network: T, isValidated: Boolean): Boolean {
        if (!isValidated) {
            if (current == network) current = null
            return false
        }
        if (current == network) return false
        current = network
        return true
    }

    fun onLost(network: T): Boolean {
        if (current != network) return false
        current = null
        return true
    }

    fun clear() {
        current = null
    }
}
