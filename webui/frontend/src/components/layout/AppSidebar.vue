<script setup lang="ts">
import { useRouter, useRoute } from 'vue-router'
import { useTasksStore } from '@/stores/tasks'
import { computed } from 'vue'

const router = useRouter()
const route = useRoute()
const tasksStore = useTasksStore()

const menuItems = [
  { label: 'Dashboard', icon: 'pi pi-home', to: '/' },
  { label: 'Docker', icon: 'pi pi-box', to: '/docker' },
  { label: 'Routen', icon: 'pi pi-directions', to: '/routes' },
  { label: 'Deploy', icon: 'pi pi-cloud-upload', to: '/deploy' },
  { label: 'Backup', icon: 'pi pi-database', to: '/backup' },
  { label: 'Netcup', icon: 'pi pi-server', to: '/netcup' },
  { label: 'Authelia', icon: 'pi pi-shield', to: '/authelia' },
  { label: 'Tasks', icon: 'pi pi-spinner', to: '/tasks' },
]

const activeTasks = computed(() => tasksStore.activeTasks().length)

function isActive(path: string) {
  if (path === '/') return route.path === '/'
  return route.path.startsWith(path)
}

function navigate(to: string) {
  router.push(to)
}
</script>

<template>
  <aside class="sidebar">
    <div class="sidebar-header">
      <i class="pi pi-server"></i>
      <span class="sidebar-title">VPS Dashboard</span>
    </div>
    <nav class="sidebar-nav">
      <button
        v-for="item in menuItems"
        :key="item.to"
        class="nav-item"
        :class="{ active: isActive(item.to) }"
        @click="navigate(item.to)"
      >
        <i :class="item.icon"></i>
        <span>{{ item.label }}</span>
        <span
          v-if="item.to === '/tasks' && activeTasks > 0"
          class="badge"
        >
          {{ activeTasks }}
        </span>
      </button>
    </nav>
  </aside>
</template>

<style scoped>
.sidebar {
  width: var(--sidebar-width);
  height: 100vh;
  background: var(--p-surface-card);
  border-right: 1px solid var(--p-surface-border);
  display: flex;
  flex-direction: column;
  position: fixed;
  left: 0;
  top: 0;
  z-index: 100;
}

.sidebar-header {
  padding: 1.25rem 1rem;
  display: flex;
  align-items: center;
  gap: 0.75rem;
  border-bottom: 1px solid var(--p-surface-border);
}

.sidebar-header i {
  font-size: 1.5rem;
  color: var(--p-primary-color);
}

.sidebar-title {
  font-size: 1.125rem;
  font-weight: 700;
  color: var(--p-text-color);
}

.sidebar-nav {
  padding: 0.5rem;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow-y: auto;
  flex: 1;
}

.nav-item {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.75rem 1rem;
  border: none;
  background: none;
  color: var(--p-text-muted-color);
  cursor: pointer;
  border-radius: var(--p-border-radius);
  font-size: 0.875rem;
  transition: all 0.15s;
  width: 100%;
  text-align: left;
}

.nav-item:hover {
  background: var(--p-surface-hover);
  color: var(--p-text-color);
}

.nav-item.active {
  background: var(--p-primary-color);
  color: var(--p-primary-contrast-color);
}

.nav-item i {
  font-size: 1rem;
  width: 1.25rem;
  text-align: center;
}

.badge {
  margin-left: auto;
  background: var(--p-red-500);
  color: white;
  font-size: 0.7rem;
  font-weight: 700;
  padding: 0.15rem 0.45rem;
  border-radius: 9999px;
  min-width: 1.25rem;
  text-align: center;
}
</style>
