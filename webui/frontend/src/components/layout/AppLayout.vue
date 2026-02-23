<script setup lang="ts">
import { ref } from 'vue'
import AppSidebar from './AppSidebar.vue'
import AppHeader from './AppHeader.vue'
import BottomNav from './BottomNav.vue'
import Toast from 'primevue/toast'
import Drawer from 'primevue/drawer'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()
const drawerVisible = ref(false)

function openDrawer() {
  drawerVisible.value = true
}

function closeDrawer() {
  drawerVisible.value = false
}
</script>

<template>
  <div class="app-layout">
    <!-- Desktop: feste Sidebar -->
    <AppSidebar v-if="!isMobile" />

    <!-- Mobile: Drawer-Sidebar -->
    <Drawer
      v-if="isMobile"
      v-model:visible="drawerVisible"
      :showCloseIcon="false"
      class="mobile-drawer"
    >
      <AppSidebar :mobile="true" @navigate="closeDrawer" />
    </Drawer>

    <div class="main-area" :class="{ 'mobile-main': isMobile }">
      <AppHeader :mobile="isMobile" @toggle-menu="openDrawer" />
      <main class="main-content" :class="{ 'mobile-content': isMobile }">
        <Toast position="top-right" />
        <slot />
      </main>
    </div>

    <!-- Mobile: Bottom-Navigation -->
    <BottomNav v-if="isMobile" />
  </div>
</template>

<style scoped>
.app-layout {
  display: flex;
  min-height: 100vh;
}

.main-area {
  flex: 1;
  margin-left: var(--sidebar-width);
  display: flex;
  flex-direction: column;
}

.main-area.mobile-main {
  margin-left: 0;
}

.main-content {
  flex: 1;
  padding: 1.5rem;
  overflow-y: auto;
}

.main-content.mobile-content {
  padding: 1rem 0.75rem;
  padding-bottom: calc(60px + 0.75rem);
}
</style>

<style>
.mobile-drawer .p-drawer-content {
  padding: 0;
}

.mobile-drawer .p-drawer-header {
  display: none;
}

.mobile-drawer {
  width: 280px !important;
}
</style>
