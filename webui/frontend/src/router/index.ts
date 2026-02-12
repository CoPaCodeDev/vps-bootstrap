import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      name: 'dashboard',
      component: () => import('@/views/DashboardView.vue'),
    },
    {
      path: '/vps/:host',
      name: 'vps-detail',
      component: () => import('@/views/VpsDetailView.vue'),
      props: true,
    },
    {
      path: '/docker',
      name: 'docker',
      component: () => import('@/views/DockerView.vue'),
    },
    {
      path: '/routes',
      name: 'routes',
      component: () => import('@/views/RoutesView.vue'),
    },
    {
      path: '/deploy',
      name: 'deploy',
      component: () => import('@/views/DeployView.vue'),
    },
    {
      path: '/deploy/wizard/:template',
      name: 'deploy-wizard',
      component: () => import('@/views/DeployWizardView.vue'),
      props: true,
    },
    {
      path: '/backup',
      name: 'backup',
      component: () => import('@/views/BackupView.vue'),
    },
    {
      path: '/netcup',
      name: 'netcup',
      component: () => import('@/views/NetcupView.vue'),
    },
    {
      path: '/authelia',
      name: 'authelia',
      component: () => import('@/views/AutheliaView.vue'),
    },
    {
      path: '/tasks',
      name: 'tasks',
      component: () => import('@/views/TasksView.vue'),
    },
  ],
})

export default router
