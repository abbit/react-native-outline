import {
  NativeModulesProxy,
  EventEmitter,
  Subscription,
} from "expo-modules-core";

// Import the native module
// and on native platforms to OutlineApi.ts
import OutlineApiModule from "./src/OutlineApiModule";
import {
  ChangeEventPayload,
  ShadowsocksSessionConfig,
  Tunnel,
} from "./src/OutlineApi.types";
import { SHADOWSOCKS_URI } from "ShadowsocksConfig";

// Get the native constant value.
export const PI = OutlineApiModule.PI;

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

export function prepareVPN(): Promise<string> {
  return OutlineApiModule.prepareVpn();
}

// If "possiblyInviteUul" is a URL whose fragment contains a Shadowsocks URL
// then return that Shadowsocks URL, otherwise return the original string.
export function unwrapInvite(possiblyInviteUrl: string): string {
  try {
    const url = new URL(possiblyInviteUrl);
    if (url.hash) {
      const decodedFragment = decodeURIComponent(url.hash);

      // Search in the fragment for ss:// for two reasons:
      //  - URL.hash includes the leading # (what).
      //  - When a user opens invite.html#ENCODEDSSURL in their browser, the website (currently)
      //    redirects to invite.html#/en/invite/ENCODEDSSURL. Since copying that redirected URL
      //    seems like a reasonable thing to do, let's support those URLs too.
      //  - Dynamic keys are not supported by the invite flow, so we don't need to check for them
      const possibleShadowsocksUrl = decodedFragment.substring(
        decodedFragment.indexOf("ss://")
      );

      if (new URL(possibleShadowsocksUrl).protocol === "ss:") {
        return possibleShadowsocksUrl;
      }
    }
  } catch (e) {
    // It wasn't an invite URL!
    console.log("Failed to parse invite URL", e);
  }

  return possiblyInviteUrl;
}

// Parses an access key string into a ShadowsocksConfig object.
export function staticKeyToShadowsocksSessionConfig(
  staticKey: string
): ShadowsocksSessionConfig {
  try {
    const config = SHADOWSOCKS_URI.parse(staticKey);
    return {
      host: config.host.data,
      port: config.port.data,
      method: config.method.data,
      password: config.password.data,
      prefix: config.extra?.["prefix"],
    };
  } catch (cause) {
    console.log("Failed to parse static access key", cause);
    throw new Error("Invalid static access key.");
  }
}

class MobileTunnel implements Tunnel {
  constructor(public id: string) {}

  async start(accessKey: string) {
    let errCode = -1;
    try {
      const invite = unwrapInvite(accessKey);
      console.log("invite", invite);
      const config = staticKeyToShadowsocksSessionConfig(invite);
      console.log("config", config);
      errCode = await OutlineApiModule.startVpn(this.id, config);
    } catch (cause) {
      console.log("Failed to parse static access key", cause);
      throw new Error("Invalid static access key.");
    }

    if (errCode !== 0) {
      console.warn("Failed to start tunnel", errCode);
      throw new Error("FailedToStartTunnel");
    }
  }

  async stop() {
    const errCode = await OutlineApiModule.stopVpn(this.id);
    if (errCode !== 0) {
      console.warn("Failed to stop tunnel", errCode);
      throw new Error("FailedToStopTunnel");
    }
  }

  async isRunning() {
    return OutlineApiModule.isVpnActive(this.id);
  }
}

export function createTunnel(): Tunnel {
  return new MobileTunnel("mobile");
}
