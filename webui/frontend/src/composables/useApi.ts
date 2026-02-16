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

      let resp: Response
      try {
        resp = await fetch(`${API_BASE}${path}`, opts)
      } catch {
        // CORS-Fehler durch Auth-Redirect (Authelia-Session abgelaufen)
        window.location.reload()
        throw { status: 401, detail: 'Sitzung abgelaufen' } as ApiError
      }

      // Redirect zur Auth-Seite (gleiche Origin, kein CORS)
      if (resp.redirected && !resp.url.includes(API_BASE)) {
        window.location.reload()
        throw { status: 401, detail: 'Sitzung abgelaufen' } as ApiError
      }

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

  async function upload<T>(path: string, formData: FormData): Promise<T> {
    loading.value = true
    error.value = null

    try {
      const resp = await fetch(`${API_BASE}${path}`, {
        method: 'POST',
        body: formData,
      })

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

  return { loading, error, get, post, del, upload }
}
