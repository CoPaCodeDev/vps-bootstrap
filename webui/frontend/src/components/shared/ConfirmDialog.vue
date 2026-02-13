<script setup lang="ts">
import Dialog from 'primevue/dialog'
import Button from 'primevue/button'

const props = defineProps<{
  visible: boolean
  header: string
  message: string
  confirmLabel?: string
  severity?: string
}>()

const emit = defineEmits<{
  confirm: []
  cancel: []
}>()
</script>

<template>
  <Dialog
    :visible="visible"
    :header="header"
    :modal="true"
    :closable="true"
    :style="{ width: '28rem' }"
    @update:visible="!$event && emit('cancel')"
  >
    <p>{{ message }}</p>
    <template #footer>
      <Button label="Abbrechen" text @click="emit('cancel')" />
      <Button
        :label="confirmLabel || 'Bestätigen'"
        :severity="(severity as any) || 'primary'"
        @click="emit('confirm')"
      />
    </template>
  </Dialog>
</template>
