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
  // Stock-changing disposition is separate from inspection verify.
  const canDisposition = can("damage.disposition")
  const canDispose = can("damage.dispose")
  const canMonitor = can("operations.monitor")
  const canCreate = canOpenDamageCreate(can)
  const availableScenarios = scenariosAvailableForPermissions(can)
  const canTransitOnly =
    can("deliveries.execute") && !canRead && !canRecord && !canVerify
  const isAdminMonitor = canMonitor && !canVerify
  const showVerificationQueues = canVerify || canMonitor
  const showDispositionQueues = canDisposition || canMonitor
  const showExceptionalQueues = damageExceptionalQueuePermissions.some(
    (permission) => can(permission),
  )
  const canRequestExceptional = canDisposition
  const canApproveExceptional = canDispose
  const canExecuteExceptional = canDisposition
  const canViewExceptionalQueue = showExceptionalQueues
  const canViewQuarantine = damageQuarantinePermissions.some((permission) =>
    can(permission),
  )
  const canConfirmCustody = canRecord && canVerify
  const canTransferQuarantine = canDisposition
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
    canDisposition,
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
