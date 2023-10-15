import {
  NativeModulesProxy,
  EventEmitter,
  Subscription,
} from "expo-modules-core";

// Import the native module
// and on native platforms to OutlineApi.ts
import OutlineApiModule from "./src/OutlineApiModule";
import {
  TunnelStatusEventPayload,
  ShadowsocksSessionConfig,
  Tunnel,
  EventName,
  TunnelStatus,
} from "./src/OutlineApi.types";
import { SHADOWSOCKS_URI } from "ShadowsocksConfig";

export { TunnelStatus };

const emitter = new EventEmitter(
  OutlineApiModule ?? NativeModulesProxy.OutlineApi
);

function addTunnelStatusListener(
  listener: (event: TunnelStatusEventPayload) => void
): Subscription {
  return emitter.addListener<TunnelStatusEventPayload>(
    EventName.TUNNEL_STATUS_CHANGED,
    listener
  );
}

export function prepareVPN(): boolean {
  return OutlineApiModule.prepareVpn();
}

// If "possiblyInviteUrl" is a URL whose fragment contains a Shadowsocks URL
// then return that Shadowsocks URL, otherwise return the original string.
// adapted from https://github.com/Jigsaw-Code/outline-client/blob/afd41e08a9e75664211397c2d3ecd6040275a807/src/www/app/app.ts#L39
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
// adapted from https://github.com/Jigsaw-Code/outline-client/blob/afd41e08a9e75664211397c2d3ecd6040275a807/src/www/app/outline_server_repository/access_key_serialization.ts#L24
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
  private statusChangeSubscription: Subscription | null = null;

  constructor(public id: string) {}

  async start(accessKey: string) {
    let config: ShadowsocksSessionConfig;
    try {
      const invite = unwrapInvite(accessKey);
      console.log("invite", invite);
      config = staticKeyToShadowsocksSessionConfig(invite);
    } catch (cause) {
      console.log("Failed to parse static access key", cause);
      throw new Error("Invalid static access key.");
    }

    let errCode = -1;
    try {
      console.log("config", config);
      errCode = await OutlineApiModule.startVpn(this.id, config);
    } catch (cause) {
      console.log("Failed to start VPN", cause);
      throw new Error("FailedToStartVpn");
    }

    if (errCode !== 0) {
      console.warn("Failed to start tunnel", errCode);
      throw new Error("FailedToStartTunnel");
    }
  }

  async stop() {
    let errCode = -1;
    try {
      const errCode = await OutlineApiModule.stopVpn(this.id);
    } catch (cause) {
      console.log("Failed to stop VPN", cause);
      throw new Error("FailedToStopVpn");
    }

    if (errCode !== 0) {
      console.warn("Failed to stop tunnel", errCode);
      throw new Error("FailedToStopTunnel");
    }
  }

  async isRunning() {
    return OutlineApiModule.isVpnActive(this.id);
  }

  onStatusChange(listener: (status: TunnelStatus) => void) {
    this.statusChangeSubscription = addTunnelStatusListener((event) => {
      if (event.tunnelId === this.id) {
        listener(event.status);
      }
    });
  }

  removeStatusChangeListener() {
    if (this.statusChangeSubscription) {
      this.statusChangeSubscription.remove();
      this.statusChangeSubscription = null;
    }
  }
}

export function createTunnel(): Tunnel {
  return new MobileTunnel("mobile");
}
