// main.js
const { app, BrowserWindow } = require('electron');

function createWindow () {
  const win = new BrowserWindow({
    width: 2560,
    height: 1440,
    webPreferences: {
      nodeIntegration: false
    }
  });

  win.loadURL('https://www.geoguessr.com/');
}

app.whenReady().then(createWindow);
