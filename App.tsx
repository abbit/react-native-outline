import { StatusBar } from "expo-status-bar";
import { useState } from "react";
import { StyleSheet, Text, View, Button, TextInput } from "react-native";
import { hello } from "./modules/outline-api";

export default function App() {
  const [accessKey, setAccessKey] = useState("");
  const [isConnected, setIsConnected] = useState(false);

  const connectToOutline = async () => {
    console.log(`Connecting to Outline with access key: ${accessKey}`);
    setIsConnected(true);
  };

  const disconnectFromOutline = async () => {
    console.log(`Disconnecting from Outline`);
    setIsConnected(false);
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
      <Text>Outline API says: {hello()}</Text>
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
