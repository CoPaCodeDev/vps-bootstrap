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
  -webkit-text-size-adjust: 100%;
}

.dark body {
  color-scheme: dark;
}

/* Mobile: Page-Header stacken */
@media (max-width: 767px) {
  .page-header {
    flex-direction: column;
    align-items: flex-start !important;
    gap: 0.75rem;
  }

  .page-header .actions {
    width: 100%;
    flex-wrap: wrap;
  }

  .page-header .actions .p-button .p-button-label {
    display: none;
  }

  .page-header .actions .p-button {
    padding: 0.5rem;
  }

  /* DataTable horizontal scrollbar */
  .p-datatable-table-container {
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }

  /* Dialog volle Breite */
  .p-dialog {
    width: calc(100vw - 1.5rem) !important;
    max-width: calc(100vw - 1.5rem) !important;
    margin: 0.75rem;
  }

  .p-dialog .p-dialog-content {
    padding: 0.75rem;
  }
}
</style>
