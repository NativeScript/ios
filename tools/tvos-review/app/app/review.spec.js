import { describe, it, expect } from 'vitest';
import { Device, isTvOS, knownFolders } from '@nativescript/core';
import { Canvas, ImageData, GPU, GPUBufferUsage, GPUMapMode } from '@nativescript/canvas';
import { mount } from '@nativescript/unit-test-runner/testing';

import { checkImageDataOwnership } from './imagedata-ownership';

async function surface(type) {
  const canvas = new Canvas();
  canvas.width = 160;
  canvas.height = 120;
  const ready = new Promise(resolve => canvas.once('ready', resolve));
  await mount(canvas);
  await ready;
  return canvas.getContext(type);
}

describe('tvOS integration', () => {
  it('reports tvOS and writes to the cache', () => {
    expect(isTvOS).toBe(true);
    expect(Device.os).toBe('tvOS');
    const file = knownFolders.temp().getFile('review-write.txt');
    file.writeTextSync('tvOS');
    expect(file.readTextSync()).toBe('tvOS');
  });

  it('round-trips Canvas pixels and Unicode text metrics', async () => {
    const context = await surface('2d');
    context.fillStyle = '#00e5ff';
    context.fillRect(0, 0, 100, 100);
    expect(Array.from(context.getImageData(10, 10, 1, 1).data)).toEqual([0, 229, 255, 255]);
    context.font = '24px sans-serif';
    expect(context.measureText('Canvas é 🕹').width).toBeGreaterThan(0);
    context.fillText('Canvas é 🕹', 5, 30);
  });

  it('keeps ImageData pixel views alive across garbage collection', async () => {
    expect(await checkImageDataOwnership(ImageData)).toEqual({ allocations: 4096, retainedViews: 64 });
  });

  it('uses WebGL typed buffers and reads a cleared pixel', async () => {
    const gl = await surface('webgl');
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 1, 2, 3]), gl.STATIC_DRAW);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, new Float32Array([4, 5]));
    expect(gl.getBufferParameter(gl.ARRAY_BUFFER, gl.BUFFER_SIZE)).toBe(16);
    gl.clearColor(1, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const pixel = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
    expect(Array.from(pixel)).toEqual([255, 0, 0, 255]);
    expect(gl.getError()).toBe(gl.NO_ERROR);
    gl.deleteBuffer(buffer);
  });

  it('destroys WebGPU query resources', async () => {
    const adapter = await new GPU().requestAdapter();
    const device = await adapter.requestDevice();
    const query = device.createQuerySet({ type: 'occlusion', count: 1 });
    query.destroy();
    device.destroy();
  });
});
