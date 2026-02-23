<script setup lang="ts">
import { useRouter, useRoute } from 'vue-router'
import { useTasksStore } from '@/stores/tasks'
import { computed } from 'vue'

const router = useRouter()
const route = useRoute()
const tasksStore = useTasksStore()

const items = [
  { label: 'Home', icon: 'pi pi-home', to: '/' },
  { label: 'Docker', icon: 'pi pi-box', to: '/docker' },
  { label: 'Routen', icon: 'pi pi-directions', to: '/routes' },
  { label: 'Deploy', icon: 'pi pi-cloud-upload', to: '/deploy' },
  { label: 'Tasks', icon: 'pi pi-spinner', to: '/tasks' },
]

const activeTasks = computed(() => tasksStore.activeTasks().length)

function isActive(path: string) {
  if (path === '/') return route.path === '/'
  return route.path.startsWith(path)
}
</script>

<template>
  <nav class="bottom-nav">
    <button
      v-for="item in items"
      :key="item.to"
      class="bottom-nav-item"
      :class="{ active: isActive(item.to) }"
      @click="router.push(item.to)"
    >
      <div class="icon-wrapper">
        <i :class="item.icon"></i>
        <span
          v-if="item.to === '/tasks' && activeTasks > 0"
          class="badge"
        >{{ activeTasks }}</span>
      </div>
      <span class="label">{{ item.label }}</span>
    </button>
  </nav>
</template>

<style scoped>
.bottom-nav {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  height: 60px;
  background: var(--p-surface-card);
  border-top: 1px solid var(--p-surface-border);
  display: flex;
  justify-content: space-around;
  align-items: center;
  z-index: 200;
  padding-bottom: env(safe-area-inset-bottom, 0);
}

.bottom-nav-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.15rem;
  border: none;
  background: none;
  color: var(--p-text-muted-color);
  cursor: pointer;
  padding: 0.35rem 0.75rem;
  min-width: 56px;
  min-height: 44px;
  transition: color 0.15s;
}

.bottom-nav-item.active {
  color: var(--p-primary-color);
}

.icon-wrapper {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
}

.icon-wrapper i {
  font-size: 1.15rem;
}

.badge {
  position: absolute;
  top: -6px;
  right: -10px;
  background: var(--p-red-500);
  color: white;
  font-size: 0.6rem;
  font-weight: 700;
  padding: 0.1rem 0.3rem;
  border-radius: 9999px;
  min-width: 1rem;
  text-align: center;
  line-height: 1;
}

.label {
  font-size: 0.65rem;
  font-weight: 500;
}
</style>
