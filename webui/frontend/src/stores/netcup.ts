import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useApi } from '@/composables/useApi'

export const useNetcupStore = defineStore('netcup', () => {
  const loggedIn = ref(false)
  const servers = ref<any[]>([])
  const loading = ref(false)
  const loginSessionId = ref<string | null>(null)

  const api = useApi()

  async function startLogin() {
    const result = await api.post<{
      session_id: string
      verification_uri: string
      user_code: string
      expires_in: number
    }>('/netcup/login/device')

    loginSessionId.value = result.session_id
    return result
  }

  async function checkLoginStatus(): Promise<string> {
    if (!loginSessionId.value) return 'error'
    const result = await api.get<{ status: string; message: string }>(
      `/netcup/login/status/${loginSessionId.value}`,
    )
    if (result.status === 'success') {
      loggedIn.value = true
      loginSessionId.value = null
    }
    return result.status
  }

  async function logout() {
    await api.post('/netcup/logout')
    loggedIn.value = false
    servers.value = []
  }

  async function fetchServers() {
    loading.value = true
    try {
      servers.value = await api.get<any[]>('/netcup/servers')
      loggedIn.value = true
    } catch {
      loggedIn.value = false
    } finally {
      loading.value = false
    }
  }

  return { loggedIn, servers, loading, loginSessionId, startLogin, checkLoginStatus, logout, fetchServers }
})
