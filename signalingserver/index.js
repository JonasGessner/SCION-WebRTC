var express = require("express"),
    WebSocket = require("ws"),
    config = require(__dirname + "/config.json");

var app = express(),
    server = app.listen(config.port, '0.0.0.0'),
    wss = new WebSocket.Server({
        server: server
    });

console.log("Server listening on port " + config.port);

var allConnectedSockets = [];

wss.on("connection", function (socket) {
    allConnectedSockets.push(socket);

    socket.on("message", function (data) {
        allConnectedSockets.forEach(function (someSocket) {
            if (someSocket !== socket) {
                someSocket.send(data);
            }
        });
    });

    socket.on("close", function () {
        var idx = allConnectedSockets.indexOf(socket);
        allConnectedSockets.splice(idx, 1);
    });
});

