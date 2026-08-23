import { svelte } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [svelte()],
  base: '/',
  build: {
    outDir: '../Player/ReceiverWeb',
    emptyOutDir: true,
    sourcemap: false,
    target: 'safari17'
  }
});
