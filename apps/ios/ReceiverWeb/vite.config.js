import { svelte } from '@sveltejs/vite-plugin-svelte';
import { svelteTesting } from '@testing-library/svelte/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [svelte(), svelteTesting()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./test/setup.js']
  },
  base: '/',
  build: {
    outDir: '../Player/ReceiverWeb',
    emptyOutDir: true,
    sourcemap: false,
    target: 'safari17'
  }
});
