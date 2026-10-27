export type RefillQueueFilterState = {
  search: string
  status: string
  supplierId: string
  godownId: string
  communication: string
  acknowledgement: string
  dispatch: string
  receiving: string
  createdFrom: string
  createdTo: string
}

export const emptyRefillQueueFilters: RefillQueueFilterState = {
  search: "",
  status: "all",
  supplierId: "all",
  godownId: "all",
  communication: "all",
  acknowledgement: "all",
  dispatch: "all",
  receiving: "all",
  createdFrom: "",
  createdTo: "",
}
