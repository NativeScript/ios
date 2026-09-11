import { Application, StackLayout, Label, knownFolders, isTvOS, Device } from '@nativescript/core';
import { Canvas } from '@nativescript/canvas';
Application.run({ create() {
  const page = new StackLayout();
  page.backgroundColor = '#091325';
  const status = new Label();
  status.text = 'tvOS runtime review';
  status.color = '#ffffff';
  status.fontSize = 36;
  status.margin = 40;
  page.addChild(status);
  const canvas = new Canvas();
  canvas.marginLeft = 75;
  canvas.marginRight = 75;
  canvas.width = 640;
  canvas.height = 360;
  canvas.on('ready', () => {
    try {
      if (!isTvOS || Device.os !== 'tvOS') throw new Error('Incorrect platform identity');
      const context = canvas.getContext('2d');
      context.fillStyle = '#00e5ff';
      context.fillRect(0, 0, 640, 360);
      context.fillStyle = '#091325';
      context.font = '32px sans-serif';
      context.fillText('Canvas + V8 14.9', 240, 80);
      const sample = context.getImageData(10, 10, 1, 1).data;
      if (sample[1] < 200 || sample[2] < 200) throw new Error('Canvas pixel check failed');
      const result = { passed: true, platform: Device.os, pixels: Array.from(sample), runtime: '9.1.0' };
      knownFolders.temp().getFile('tvos-review.json').writeTextSync(JSON.stringify(result));
      status.text = 'PASS: platform, Canvas and pixel readback';
      console.log('TVOS_REVIEW_PASS ' + JSON.stringify(result));
    } catch (error) {
      status.text = 'FAIL: ' + error.message;
      console.error('TVOS_REVIEW_FAIL ' + error.stack);
    }
  });
  page.addChild(canvas);
  return page;
}});
