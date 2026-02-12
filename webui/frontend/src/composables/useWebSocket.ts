import { ref, onUnmounted } from 'vue'

export function useWebSocket(url: string) {
  const messages = ref<string[]>([])
  const connected = ref(false)
  const finished = ref(false)
  const status = ref<string>('')
  let ws: WebSocket | null = null

  function connect() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = `${protocol}//${window.location.host}${url}`
    ws = new WebSocket(wsUrl)

    ws.onopen = () => {
      connected.value = true
    }

    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data)
        if (data.type === 'output') {
          messages.value.push(data.data)
        } else if (data.type === 'status') {
          status.value = data.status
          finished.value = true
        } else if (data.type === 'error') {
          messages.value.push(`FEHLER: ${data.message}`)
          finished.value = true
        }
      } catch {
        messages.value.push(event.data)
      }
    }

    ws.onclose = () => {
      connected.value = false
    }

    ws.onerror = () => {
      connected.value = false
    }
  }

  function disconnect() {
    if (ws) {
      ws.close()
      ws = null
    }
  }

  onUnmounted(() => disconnect())

  return { messages, connected, finished, status, connect, disconnect }
}
