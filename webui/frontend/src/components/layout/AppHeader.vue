<script setup lang="ts">
import { ref, onMounted } from 'vue'

defineProps<{
  mobile?: boolean
}>()

defineEmits<{
  'toggle-menu': []
}>()

const darkMode = ref(false)
const userName = ref('Dashboard')

onMounted(() => {
  darkMode.value = localStorage.getItem('darkMode') === 'true'
  applyDarkMode()
})

function toggleDarkMode() {
  darkMode.value = !darkMode.value
  localStorage.setItem('darkMode', String(darkMode.value))
  applyDarkMode()
}

function applyDarkMode() {
  if (darkMode.value) {
    document.documentElement.classList.add('dark')
  } else {
    document.documentElement.classList.remove('dark')
  }
}
</script>

<template>
  <header class="app-header">
    <div class="header-left">
      <button v-if="mobile" class="icon-btn hamburger" @click="$emit('toggle-menu')">
        <i class="pi pi-bars"></i>
      </button>
      <slot name="title">
        <h1 class="page-title"><slot /></h1>
      </slot>
    </div>
    <div class="header-right">
      <button class="icon-btn" @click="toggleDarkMode" :title="darkMode ? 'Light Mode' : 'Dark Mode'">
        <i :class="darkMode ? 'pi pi-sun' : 'pi pi-moon'"></i>
      </button>
      <div v-if="!mobile" class="user-info">
        <i class="pi pi-user"></i>
        <span>{{ userName }}</span>
      </div>
    </div>
  </header>
</template>

<style scoped>
.app-header {
  height: var(--header-height);
  padding: 0 1.5rem;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-bottom: 1px solid var(--p-surface-border);
  background: var(--p-surface-card);
}

.header-left {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.page-title {
  font-size: 1.125rem;
  font-weight: 600;
  color: var(--p-text-color);
}

.header-right {
  display: flex;
  align-items: center;
  gap: 1rem;
}

.icon-btn {
  background: none;
  border: 1px solid var(--p-surface-border);
  border-radius: var(--p-border-radius);
  padding: 0.5rem;
  cursor: pointer;
  color: var(--p-text-muted-color);
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.15s;
  min-width: 44px;
  min-height: 44px;
}

.icon-btn:hover {
  background: var(--p-surface-hover);
  color: var(--p-text-color);
}

.hamburger {
  border: none;
  font-size: 1.25rem;
}

.user-info {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  color: var(--p-text-muted-color);
  font-size: 0.875rem;
}
</style>
