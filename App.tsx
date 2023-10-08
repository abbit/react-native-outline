import "react-native-url-polyfill/auto";
import { StatusBar } from "expo-status-bar";
import { useState } from "react";
import { StyleSheet, Text, View, Button, TextInput } from "react-native";
import { prepareVPN, createTunnel } from "./modules/outline-api";
import { Tunnel } from "./modules/outline-api/src/OutlineApi.types";

export default function App() {
  const [accessKey, setAccessKey] = useState("");
  const [isConnected, setIsConnected] = useState(false);
  const [tunnel] = useState<Tunnel>(createTunnel);

  const connectToOutline = async () => {
    console.log(`Connecting to Outline with access key: ${accessKey}`);
    try {
      await tunnel.start(accessKey);
      setIsConnected(true);
    } catch (error) {
      console.log("Failed to start tunnel", error);
    }
  };

  const disconnectFromOutline = async () => {
    console.log(`Disconnecting from Outline`);
    try {
      await tunnel.stop();
      setIsConnected(false);
    } catch (error) {
      console.log("Failed to stop tunnel", error);
    }
  };

  const toggleOutlineConnection = async () => {
    return isConnected ? disconnectFromOutline() : connectToOutline();
  };

  const onPreparePress = () => {
    console.log("Preparing VPN");
    console.log(prepareVPN());
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
      <Button title="Prepare VPN" onPress={onPreparePress} />
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
