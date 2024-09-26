# react-native-ble-wit

A React Native WIT Bluetooth Low Energy library.

## Introduction

The library is a simple React Native connection with the WITSDK

## Requirements

RN 0.60+

RN 0.40-0.59 supported until 6.7.X
RN 0.30-0.39 supported until 2.4.3

## Supported Platforms

- iOS 10+
- Android (API 19+)

## Install

```shell
npm i --save react-native-ble-wit
```

The library support the react native autolink feature.

## Documentation

## Example

The easiest way to test is simple make your AppRegistry point to our example component, like this:

```javascript
// in your index.ios.js or index.android.js
import React, { Component } from "react";
import { AppRegistry } from "react-native";
import App from "react-native-ble-wit/example/App"; //<-- simply point to the example js!
/* 
Note: The react-native-ble-wit/example directory is only included when cloning the repo, the above import will not work 
if trying to import react-native-ble-wit/example from node_modules
*/
AppRegistry.registerComponent("MyAwesomeApp", () => App);
```

Or, [use the example directly](example)

## Library development

- the library is written in typescript and needs to be built before being used for publication or local development, using the provided npm scripts in `package.json`.
- the local `example` project is configured to work with the locally built version of the library. To be able to run it, you need to build at least once the library so that its outputs listed as entrypoint in `package.json` (in the `dist` folder) are properly generated for consumption by the example project:

from the root folder:

```shell
npm install
npm run build
```

> if you are modifying the typescript files of the library (in `src/`) on the fly, you can run `npm run watch` instead. If you are modifying files from the native counterparts, you'll need to rebuild the whole app for your target environnement (`npm run android/ios`).
