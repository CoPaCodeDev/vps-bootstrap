import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useApi } from '@/composables/useApi'

export interface VPS {
  name: string
  host: string
  ip: string
  description: string
  managed: boolean
}

export interface VPSStatus {
  host: string
  online: boolean
  load: string
  uptime: string
  updates_available: number
  reboot_required: boolean
  kernel: string
  memory_used: string
  memory_total: string
  disk_used: string
  disk_total: string
}

export const useVpsStore = defineStore('vps', () => {
  const hosts = ref<VPS[]>([])
  const statuses = ref<Record<string, VPSStatus>>({})
  const loading = ref(false)

  const api = useApi()

  async function fetchHosts() {
    loading.value = true
    try {
      hosts.value = await api.get<VPS[]>('/vps/')
    } finally {
      loading.value = false
    }
  }

  async function fetchStatus(host: string) {
    try {
      const status = await api.get<VPSStatus>(`/vps/${host}/status`)
      statuses.value[host] = status
    } catch {
      statuses.value[host] = {
        host,
        online: false,
        load: '',
        uptime: '',
        updates_available: 0,
        reboot_required: false,
        kernel: '',
        memory_used: '',
        memory_total: '',
        disk_used: '',
        disk_total: '',
      }
    }
  }

  async function fetchAllStatuses() {
    const promises = hosts.value.map((h) => fetchStatus(h.name))
    await Promise.allSettled(promises)
  }

  return { hosts, statuses, loading, fetchHosts, fetchStatus, fetchAllStatuses }
})
