import { defineConfig } from 'vitest/config';
import { nativeScript } from '@nativescript/unit-test-runner';
import path from 'node:path';
const device = process.env.NS_DEVICE;
export default defineConfig({
  plugins: [nativeScript({
    platform: process.env.NS_PLATFORM || 'tvos',
    device,
    connectTimeout: 300000,
    launchCommand: {
      command: process.execPath,
      args: [path.resolve('../cli/bin/tns'), 'run', 'tvos', '--no-local-cli', '--no-hmr', '--env.unitTesting', '--env.testRunnerPort=17878', ...(device ? ['--device', device] : [])],
    },
  })],
  test: { testTimeout: 60000 },
});
