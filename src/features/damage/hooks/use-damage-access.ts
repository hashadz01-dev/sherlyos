import { useAccess } from "@/lib/access/use-access"
import {
  canOpenDamageCreate,
  damageExceptionalQueuePermissions,
  damageNavPermissions,
  damageQuarantinePermissions,
  damageVerificationPermissions,
  scenariosAvailableForPermissions,
} from "@/lib/damage/rules"

/** UX-only damage capability flags. Backend RPCs remain authoritative. */
export function useDamageAccess() {
  const access = useAccess()
  const can = access.can
  const canOpenDamage = damageNavPermissions.some((permission) =>
    can(permission),
  )
  const canRead = can("damage.read") || can("operations.monitor")
  const canRecord = can("damage.record")
  const canVerify = can("damage.verify")
  const canDispose = can("damage.dispose")
  const canMonitor = can("operations.monitor")
  const canCreate = canOpenDamageCreate(can)
  const availableScenarios = scenariosAvailableForPermissions(can)
  const canTransitOnly =
    can("deliveries.execute") && !canRead && !canRecord && !canVerify
  const isAdminMonitor = canMonitor && !canVerify
  const showVerificationQueues = canVerify || canMonitor
  const showDispositionQueues = canVerify || canMonitor
  const showExceptionalQueues = damageExceptionalQueuePermissions.some(
    (permission) => can(permission),
  )
  const canRequestExceptional = canVerify
  const canApproveExceptional = canDispose
  const canExecuteExceptional = canVerify
  const canViewExceptionalQueue = showExceptionalQueues
  const canViewQuarantine = damageQuarantinePermissions.some((permission) =>
    can(permission),
  )
  const canConfirmCustody = canRecord && canVerify
  const canTransferQuarantine = canVerify
  const canViewVerification = damageVerificationPermissions.some((permission) =>
    can(permission),
  )

  return {
    loading: access.loading,
    roles: access.roles,
    can,
    canOpenDamage,
    canCreate,
    availableScenarios,
    canRead,
    canRecord,
    canVerify,
    canDispose,
    canMonitor,
    canTransitOnly,
    isAdminMonitor,
    showVerificationQueues,
    showDispositionQueues,
    showExceptionalQueues,
    canRequestExceptional,
    canApproveExceptional,
    canExecuteExceptional,
    canViewExceptionalQueue,
    canViewQuarantine,
    canConfirmCustody,
    canTransferQuarantine,
    canViewVerification,
  }
}
