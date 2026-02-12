<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  online: boolean
}>()

const color = computed(() => (props.online ? '#22c55e' : '#ef4444'))
const label = computed(() => (props.online ? 'Online' : 'Offline'))
</script>

<template>
  <span class="status-badge">
    <span class="dot" :style="{ background: color }"></span>
    {{ label }}
  </span>
</template>

<style scoped>
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  font-size: 0.8125rem;
  font-weight: 500;
}

.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  display: inline-block;
}
</style>
