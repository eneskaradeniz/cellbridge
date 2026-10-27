package com.cellbridge.telecom

import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

enum class AppRole(val roleName: String) {
    DIALER(RoleManager.ROLE_DIALER),
    SMS(RoleManager.ROLE_SMS),
}

/** Thin wrapper over [RoleManager] for the two roles the host needs. */
@Singleton
class DefaultRoles @Inject constructor(@ApplicationContext context: Context) {
    private val roleManager = context.getSystemService(RoleManager::class.java)

    fun isHeld(role: AppRole): Boolean = roleManager.isRoleHeld(role.roleName)

    fun isAvailable(role: AppRole): Boolean = roleManager.isRoleAvailable(role.roleName)

    /** Shows the system dialog that asks the user to make this app the default for [role]. */
    fun requestIntent(role: AppRole): Intent = roleManager.createRequestRoleIntent(role.roleName)
}
