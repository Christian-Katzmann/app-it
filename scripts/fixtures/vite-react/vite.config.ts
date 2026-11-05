// Vite + React shape. Detected by the vite/react/react-dom/@vitejs/plugin-react
// deps in package.json. Never imported by the suite (build-assert fixture, no
// install), so its content is irrelevant to detection. It deliberately carries
// NO server.port literal, so inspect.sh emits no hardcoded-port warning.
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({ plugins: [react()] })
