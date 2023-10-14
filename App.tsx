import "react-native-url-polyfill/auto";
import { StatusBar } from "expo-status-bar";
import { useEffect, useState } from "react";
import { StyleSheet, Text, View, Button, TextInput } from "react-native";
import { prepareVPN, createTunnel } from "./modules/outline-api";
import {
  Tunnel,
  TunnelStatus,
} from "./modules/outline-api/src/OutlineApi.types";

export default function App() {
  const [accessKey, setAccessKey] = useState("");
  const [isConnected, setIsConnected] = useState(false);
  const [tunnel] = useState<Tunnel>(createTunnel);

  useEffect(() => {
    tunnel.onStatusChange((status) => {
      console.log("Tunnel status changed", status);
      setIsConnected(status === TunnelStatus.CONNECTED);
    });

    return () => {
      tunnel.removeStatusChangeListener();
    };
  }, [tunnel]);

  const connectToOutline = async () => {
    console.log("Preparing VPN");
    try {
      const isVpnAlreadyPrepared = prepareVPN();
      if (!isVpnAlreadyPrepared) {
        return;
      }
    } catch (error) {
      console.error("Failed to prepare VPN", error);
      return;
    }

    console.log(`Connecting to Outline with access key: ${accessKey}`);
    try {
      await tunnel.start(accessKey);
    } catch (error) {
      console.error("Failed to start tunnel", error);
    }
  };

  const disconnectFromOutline = async () => {
    console.log(`Disconnecting from Outline`);
    try {
      await tunnel.stop();
    } catch (error) {
      console.error("Failed to stop tunnel", error);
    }
  };

  const toggleOutlineConnection = async () => {
    return isConnected ? disconnectFromOutline() : connectToOutline();
  };

  return (
    <View style={styles.container}>
      <StatusBar style="auto" />
      <Text style={styles.title}>React Native + Outline SDK</Text>
      <TextInput
        style={styles.input}
        placeholder="ss://access-key"
        value={accessKey}
        onChangeText={setAccessKey}
      />
      <Button
        title={isConnected ? "Disconnect" : "Connect"}
        onPress={toggleOutlineConnection}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
    gap: 40,
  },
  title: { fontSize: 20, fontWeight: "bold" },
  input: {
    height: 40,
    width: 300,
    borderColor: "gray",
    borderWidth: 1,
    borderRadius: 5,
    padding: 10,
  },
});
