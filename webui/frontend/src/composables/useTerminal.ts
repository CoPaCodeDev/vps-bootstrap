import { ref, onUnmounted } from 'vue'

export function useTerminalSocket(host: () => string) {
  const connected = ref(false)
  let ws: WebSocket | null = null

  let onDataCallback: ((data: Uint8Array) => void) | null = null
  let onConnectedCallback: (() => void) | null = null
  let onClosedCallback: ((reason: string) => void) | null = null
  let onErrorCallback: ((message: string) => void) | null = null

  function connect(cols: number, rows: number) {
    disconnect()

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = `${protocol}//${window.location.host}/api/v1/terminal/ws/${host()}?cols=${cols}&rows=${rows}`
    ws = new WebSocket(wsUrl)

    ws.onopen = () => {
      connected.value = true
    }

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data)
        if (msg.type === 'output' && onDataCallback) {
          const binary = Uint8Array.from(atob(msg.data), (c) => c.charCodeAt(0))
          onDataCallback(binary)
        } else if (msg.type === 'connected') {
          onConnectedCallback?.()
        } else if (msg.type === 'closed') {
          onClosedCallback?.(msg.reason || 'Verbindung geschlossen')
        } else if (msg.type === 'error') {
          onErrorCallback?.(msg.message || 'Unbekannter Fehler')
        }
      } catch {
        // Nicht-JSON-Nachricht ignorieren
      }
    }

    ws.onclose = () => {
      connected.value = false
      onClosedCallback?.('WebSocket geschlossen')
    }

    ws.onerror = () => {
      connected.value = false
      onErrorCallback?.('WebSocket-Verbindungsfehler')
    }
  }

  function sendInput(data: string) {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'input', data: btoa(data) }))
    }
  }

  function sendInputBinary(data: Uint8Array) {
    if (ws?.readyState === WebSocket.OPEN) {
      let binary = ''
      for (let i = 0; i < data.length; i++) {
        binary += String.fromCharCode(data[i])
      }
      ws.send(JSON.stringify({ type: 'input', data: btoa(binary) }))
    }
  }

  function sendResize(cols: number, rows: number) {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }))
    }
  }

  function disconnect() {
    if (ws) {
      ws.close()
      ws = null
    }
    connected.value = false
  }

  function onData(cb: (data: Uint8Array) => void) {
    onDataCallback = cb
  }

  function onConnected(cb: () => void) {
    onConnectedCallback = cb
  }

  function onClosed(cb: (reason: string) => void) {
    onClosedCallback = cb
  }

  function onError(cb: (message: string) => void) {
    onErrorCallback = cb
  }

  onUnmounted(() => disconnect())

  return {
    connected,
    connect,
    disconnect,
    sendInput,
    sendInputBinary,
    sendResize,
    onData,
    onConnected,
    onClosed,
    onError,
  }
}
