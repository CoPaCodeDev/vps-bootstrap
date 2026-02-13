<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { useTerminalSocket } from '@/composables/useTerminal'
import '@xterm/xterm/css/xterm.css'

const props = defineProps<{
  host: string
  active: boolean
}>()

const emit = defineEmits<{
  connected: []
  disconnected: []
  error: [message: string]
}>()

const terminalRef = ref<HTMLElement | null>(null)

let terminal: Terminal | null = null
let fitAddon: FitAddon | null = null
let resizeObserver: ResizeObserver | null = null

const socket = useTerminalSocket(() => props.host)

// Catppuccin Mocha Theme
const theme = {
  background: '#1e1e2e',
  foreground: '#cdd6f4',
  cursor: '#f5e0dc',
  cursorAccent: '#1e1e2e',
  selectionBackground: '#585b7066',
  black: '#45475a',
  red: '#f38ba8',
  green: '#a6e3a1',
  yellow: '#f9e2af',
  blue: '#89b4fa',
  magenta: '#f5c2e7',
  cyan: '#94e2d5',
  white: '#bac2de',
  brightBlack: '#585b70',
  brightRed: '#f38ba8',
  brightGreen: '#a6e3a1',
  brightYellow: '#f9e2af',
  brightBlue: '#89b4fa',
  brightMagenta: '#f5c2e7',
  brightCyan: '#94e2d5',
  brightWhite: '#a6adc8',
}

function initTerminal() {
  if (!terminalRef.value || terminal) return

  terminal = new Terminal({
    theme,
    fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
    fontSize: 13,
    cursorBlink: true,
    cursorStyle: 'block',
    allowProposedApi: true,
  })

  fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.loadAddon(new WebLinksAddon())

  terminal.open(terminalRef.value)
  fitAddon.fit()

  // Tastatureingaben an WebSocket senden
  terminal.onData((data: string) => {
    socket.sendInput(data)
  })

  terminal.onBinary((data: string) => {
    const bytes = new Uint8Array(data.length)
    for (let i = 0; i < data.length; i++) {
      bytes[i] = data.charCodeAt(i)
    }
    socket.sendInputBinary(bytes)
  })

  // Resize-Events an WebSocket senden
  terminal.onResize(({ cols, rows }) => {
    socket.sendResize(cols, rows)
  })

  // ResizeObserver für Container-Größenänderungen
  resizeObserver = new ResizeObserver(() => {
    fitAddon?.fit()
  })
  resizeObserver.observe(terminalRef.value)

  // Socket-Callbacks
  socket.onData((data: Uint8Array) => {
    terminal?.write(data)
  })

  socket.onConnected(() => {
    emit('connected')
  })

  socket.onClosed((reason: string) => {
    terminal?.write(`\r\n\x1b[33m--- ${reason} ---\x1b[0m\r\n`)
    emit('disconnected')
  })

  socket.onError((message: string) => {
    terminal?.write(`\r\n\x1b[31mFehler: ${message}\x1b[0m\r\n`)
    emit('error', message)
  })

  // Verbindung herstellen
  const dims = fitAddon.proposeDimensions()
  socket.connect(dims?.cols ?? 80, dims?.rows ?? 24)
}

function cleanup() {
  socket.disconnect()
  resizeObserver?.disconnect()
  resizeObserver = null
  terminal?.dispose()
  terminal = null
  fitAddon = null
}

onMounted(() => {
  if (props.active) {
    initTerminal()
  }
})

onBeforeUnmount(() => {
  cleanup()
})

watch(
  () => props.active,
  (active) => {
    if (active) {
      // Kurz warten bis DOM gerendert ist
      setTimeout(() => initTerminal(), 50)
    } else {
      cleanup()
    }
  },
)
</script>

<template>
  <div class="web-terminal">
    <div ref="terminalRef" class="terminal-container"></div>
    <div v-if="!socket.connected.value && props.active" class="terminal-overlay">
      <i class="pi pi-spin pi-spinner"></i>
      <span>Verbinde...</span>
    </div>
  </div>
</template>

<style scoped>
.web-terminal {
  position: relative;
  background: #1e1e2e;
  border-radius: var(--p-border-radius);
  overflow: hidden;
}

.terminal-container {
  padding: 0.5rem;
  min-height: 400px;
}

/* xterm.js Container soll volle Breite nutzen */
.terminal-container :deep(.xterm) {
  height: 100%;
}

.terminal-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  background: rgba(30, 30, 46, 0.9);
  color: #cdd6f4;
  font-size: 0.875rem;
}
</style>
