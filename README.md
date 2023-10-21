# React Native Outline

## Prerequisites

- Node.js 18 or greater
- npm

Android:

- Java 11
- Android SDK 22 or greater
- set ANDROID_HOME environment variable to Android SDK path

check Java version:

```bash
$ java -version
```

set ANDROID_HOME environment variable:

```bash
$ export ANDROID_HOME=/Users/username/Library/Android/sdk
```

iOS:

- TODO

## How to build

### Install dependencies

```bash
$ npm install
```

### Android

```bash
$ npx expo prebuild -p android
```

```bash
$ npm run android
```

### iOS

```bash
$ npx expo prebuild -p ios
```

```bash
$ pod install --project-directory=ios
```

Open ios project in Xcode:

```bash
$ xed ios
```

Set signing team in Xcode and run

Build and run

## How to use

- Enter Outline access key in the text field
- Press "Connect"
