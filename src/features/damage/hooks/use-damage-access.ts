import { useAccess } from "@/lib/access/use-access"
import {
  canOpenDamageCreate,
  damageNavPermissions,
  damageQuarantinePermissions,
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
  const canMonitor = can("operations.monitor")
  const canCreate = canOpenDamageCreate(can)
  const availableScenarios = scenariosAvailableForPermissions(can)
  const canTransitOnly =
    can("deliveries.execute") && !canRead && !canRecord && !canVerify
  const isAdminMonitor = canMonitor && !canVerify
  const showVerificationQueues = canVerify || canMonitor
  const showDispositionQueues = canVerify || canMonitor
  const showExceptionalQueues =
    canMonitor || can("stock.adjustment.approve_exceptional")
  const canViewQuarantine = damageQuarantinePermissions.some((permission) =>
    can(permission),
  )
  const canConfirmCustody = canRecord && canVerify
  const canTransferQuarantine = canVerify

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
    canMonitor,
    canTransitOnly,
    isAdminMonitor,
    showVerificationQueues,
    showDispositionQueues,
    showExceptionalQueues,
    canViewQuarantine,
    canConfirmCustody,
    canTransferQuarantine,
  }
}
