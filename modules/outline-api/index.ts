import {
  NativeModulesProxy,
  EventEmitter,
  Subscription,
} from "expo-modules-core";

// Import the native module. On web, it will be resolved to OutlineApi.web.ts
// and on native platforms to OutlineApi.ts
import OutlineApiModule from "./src/OutlineApiModule";
import { ChangeEventPayload } from "./src/OutlineApi.types";

// Get the native constant value.
export const PI = OutlineApiModule.PI;

export function hello(): string {
  return OutlineApiModule.hello();
}

export async function setValueAsync(value: string) {
  return await OutlineApiModule.setValueAsync(value);
}

const emitter = new EventEmitter(
  OutlineApiModule ?? NativeModulesProxy.OutlineApi
);

export function addChangeListener(
  listener: (event: ChangeEventPayload) => void
): Subscription {
  return emitter.addListener<ChangeEventPayload>("onChange", listener);
}

export { ChangeEventPayload };
