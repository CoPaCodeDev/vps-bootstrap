<script setup lang="ts">
import AppLayout from '@/components/layout/AppLayout.vue'
</script>

<template>
  <AppLayout>
    <router-view />
  </AppLayout>
</template>

<style>
:root {
  --sidebar-width: 260px;
  --header-height: 56px;
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--p-surface-ground);
  color: var(--p-text-color);
  min-height: 100vh;
}

.dark body {
  color-scheme: dark;
}
</style>
