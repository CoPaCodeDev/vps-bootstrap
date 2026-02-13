<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'

const props = defineProps<{
  lines: string[]
  running?: boolean
}>()

const terminalEl = ref<HTMLElement | null>(null)

watch(
  () => props.lines.length,
  async () => {
    await nextTick()
    if (terminalEl.value) {
      terminalEl.value.scrollTop = terminalEl.value.scrollHeight
    }
  },
)
</script>

<template>
  <div class="terminal" ref="terminalEl">
    <div v-for="(line, i) in lines" :key="i" class="terminal-line">{{ line }}</div>
    <div v-if="running" class="terminal-cursor">
      <i class="pi pi-spin pi-spinner"></i>
    </div>
  </div>
</template>

<style scoped>
.terminal {
  background: #1e1e2e;
  color: #cdd6f4;
  font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
  font-size: 0.8125rem;
  line-height: 1.5;
  padding: 1rem;
  border-radius: var(--p-border-radius);
  max-height: 500px;
  overflow-y: auto;
  white-space: pre-wrap;
  word-break: break-all;
}

.terminal-line {
  min-height: 1.2em;
}

.terminal-cursor {
  color: #89b4fa;
  margin-top: 0.25rem;
}
</style>
