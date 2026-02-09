// source/app.d
module app;

import deimos.openssl.ssl;
import gtk_client;
import logging;

void main() {
    logToTerminal("Starting D IRC Client with GTK 4", "INFO", "main");
    auto client = new GTKClient();
    client.run();
}
