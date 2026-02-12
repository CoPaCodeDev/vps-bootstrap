import { ref } from 'vue'

const API_BASE = '/api/v1'

export interface ApiError {
  status: number
  detail: string
}

export function useApi() {
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    loading.value = true
    error.value = null

    try {
      const opts: RequestInit = {
        method,
        headers: { 'Content-Type': 'application/json' },
      }
      if (body !== undefined) {
        opts.body = JSON.stringify(body)
      }

      const resp = await fetch(`${API_BASE}${path}`, opts)

      if (!resp.ok) {
        const data = await resp.json().catch(() => ({}))
        const msg = data.detail || `Fehler ${resp.status}`
        error.value = msg
        throw { status: resp.status, detail: msg } as ApiError
      }

      return await resp.json()
    } finally {
      loading.value = false
    }
  }

  const get = <T>(path: string) => request<T>('GET', path)
  const post = <T>(path: string, body?: unknown) => request<T>('POST', path, body)
  const del = <T>(path: string) => request<T>('DELETE', path)

  return { loading, error, get, post, del }
}
