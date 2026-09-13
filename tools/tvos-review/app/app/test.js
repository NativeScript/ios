import { createReviewSocket } from './review-socket';
import { Application } from '@nativescript/core';
import { NativeScriptVitestCoordinator, createWebpackTestRegistry } from '@nativescript/unit-test-runner/runtime';
import { createVitestHostPage } from '@nativescript/unit-test-runner/testing';
const coordinator = new NativeScriptVitestCoordinator({ createSocket: createReviewSocket, registry: createWebpackTestRegistry(require.context('./', true, /\.spec\.js$/)) });
void coordinator.start();
Application.run({ create: () => createVitestHostPage(coordinator) });
