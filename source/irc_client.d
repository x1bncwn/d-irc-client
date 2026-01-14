// source/irc_client.d
module irc_client;

import birchwood.client;
import birchwood.config;
import birchwood.protocol;
import std.concurrency;
import std.string;
import std.conv;
import std.datetime;
import std.algorithm;
import std.array;
import std.stdio;
import core.thread;
import core.time;
import core.sys.posix.unistd : write;
import core.stdc.errno : errno;
import models;
import logging;
import tracker;

class MyIRCClient : Client {
    Tid gtkTid;
    string serverName;
    bool clientRunning = true;
    Tracker tracker;
    int pipeFd;

    // WHOIS state - using the builder
    private WhoisReplyBuilder pendingWhoisBuilder;
    private bool whoisWaitingForEnd = false;
    private string whoisCurrentTarget;

    this(string server, Tid gtkTid, int pipeFd) {
        auto connInfo = ConnectionInfo.newConnection(
            server,
            6667,
            defaultNick,
            defaultNick,
            "D IRC Client"
        );
        super(connInfo);
        this.gtkTid = gtkTid;
        this.pipeFd = pipeFd;
        serverName = server;
        resetWhoisState();
        tracker = new Tracker();
        tracker.start();

        logToTerminal("MyIRCClient created for " ~ server ~ " - Tracker started", "INFO", "irc");
    }

    private void resetWhoisState() {
        // Reset the builder
        pendingWhoisBuilder = WhoisReplyBuilder(serverName, "");
        whoisWaitingForEnd = false;
        whoisCurrentTarget = "";
        logToTerminal("DEBUG: Reset WHOIS state", "DEBUG", "irc");
    }

    private void sendToGui(IrcToGtkMessage msg) {
        logToTerminal("IRC DEBUG: Sending message to GUI thread", "DEBUG", "irc");

        // Send via std.concurrency
        send(gtkTid, msg);

        // Signal pipe with just 1 byte to wake up GUI thread
        char[1] signalByte = [1];
        auto result = write(pipeFd, signalByte.ptr, 1);
        if (result == -1) {
            logToTerminal("IRC DEBUG: Failed to signal pipe: errno = " ~ to!string(errno), "ERROR", "irc");
        }
    }

    private void sendChatMessage(string channel, string rawNickname, string msgBody, bool isAction = false, bool isNotice = false, string customType = "") {
        auto now = Clock.currTime();
        string timeStr = "[" ~ format("%02d:%02d", now.hour, now.minute) ~ "]";

        char prefixChar = '\0';
        string prefixStr = "";

        if (channel.length > 0 && channel[0] == '#') {
            prefixChar = tracker.getPrefix(channel, rawNickname);
            if (prefixChar != '\0') {
                prefixStr = [prefixChar].idup;
            }
        }

        string messageType = customType.length > 0 ? customType :
                            (isAction ? "action" : (isNotice ? "notice" : "message"));

        ChatMessage chat = ChatMessage(
            serverName,
            channel,
            timeStr,
            rawNickname,
            prefixStr,
            messageType,
            msgBody
        );

        sendToGui(IrcToGtkMessage.fromChat(chat));

        string displayNick = prefixStr.length > 0 ? prefixStr ~ rawNickname : rawNickname;
        string logPrefix = channel.length > 0 ? "[" ~ channel ~ "]" : "[" ~ serverName ~ "]";
        string logMsg = logPrefix ~ " " ~ displayNick ~ (isAction ? " " : ": ") ~ msgBody;
        logToTerminal(logMsg, "INFO", "irc");
    }

    private void sendChannelUpdate(string channel, string action) {
        logToTerminal("IRC DEBUG: Sending channel update: " ~ channel ~ " - " ~ action, "DEBUG", "irc");
        ChannelUpdate update = ChannelUpdate(serverName, channel, action);
        sendToGui(IrcToGtkMessage.fromUpdate(update));
    }

    private void sendSystemMessage(string text) {
        logToTerminal("IRC DEBUG: Sending system message: " ~ text, "DEBUG", "irc");
        sendToGui(IrcToGtkMessage.fromSystem(text));
    }

    private void sendTopicMessage(string channel, string topic) {
        logToTerminal("IRC DEBUG: Sending topic message: " ~ channel ~ " - " ~ topic, "DEBUG", "irc");
        sendToGui(IrcToGtkMessage.fromTopic(ChannelTopic(serverName, channel, topic)));
    }

    private void sendWhoisResult() {
        logToTerminal("DEBUG sendWhoisResult FINAL: target='" ~ pendingWhoisBuilder.target ~
                     "' user='" ~ pendingWhoisBuilder.user ~
                     "' host='" ~ pendingWhoisBuilder.host ~
                     "' idleTime='" ~ pendingWhoisBuilder.idleTime ~
                     "' signonTime='" ~ pendingWhoisBuilder.signonTime ~
                     "' isOperator=" ~ to!string(pendingWhoisBuilder.isOperator) ~
                     "' isAway=" ~ to!string(pendingWhoisBuilder.isAway) ~
                     "' channels=" ~ to!string(pendingWhoisBuilder.channels.length) ~
                     "' actualHost='" ~ pendingWhoisBuilder.actualHost ~ "'",
                     "DEBUG", "irc");

        if (pendingWhoisBuilder.target.length > 0 &&
            pendingWhoisBuilder.user.length > 0 &&
            pendingWhoisBuilder.host.length > 0) {

            // Build immutable WhoIsReply
            WhoisReply whois = WhoisReply(pendingWhoisBuilder);

            logToTerminal("DEBUG: Sending WhoisReply for " ~ whois.target, "DEBUG", "irc");

            // Send the immutable WhoisReply directly
            send(gtkTid, whois);

            // Signal pipe with just 1 byte to wake up GUI thread
            char[1] signalByte = [1];
            auto result = write(pipeFd, signalByte.ptr, 1);
            if (result == -1) {
                logToTerminal("IRC DEBUG: Failed to signal pipe", "ERROR", "irc");
            }
        } else {
            logToTerminal("IRC DEBUG: Incomplete WHOIS data, not sending", "DEBUG", "irc");
        }
        resetWhoisState();
    }

    override void onChannelMessage(Message fullMessage, string channel, string msgBody) {
        if (channel.length > 0 && channel[0] == ':') {
            channel = channel[1..$];
        }

        string sender = fullMessage.getFrom();
        string nickname = sender;
        auto exclamation = sender.indexOf("!");
        if (exclamation != -1) {
            nickname = sender[0..exclamation];
        }

        string actualNickname = nickname;
        if (nickname.length > 0 && (nickname[0] == '@' || nickname[0] == '+' ||
            nickname[0] == '%' || nickname[0] == '&' || nickname[0] == '~')) {
            actualNickname = nickname[1..$];
            if (channel.length > 0 && channel[0] == '#') {
                char prefixChar = nickname[0];
                string[] params = [actualNickname];
                tracker.onMode(channel, "+" ~ [prefixChar].idup, params);
            }
        }

        bool isAction = false;
        if (msgBody.length > 0 && msgBody[0] == '\x01' && msgBody.endsWith("\x01")) {
            if (msgBody.length >= 8 && msgBody[1..8] == "ACTION ") {
                isAction = true;
                msgBody = msgBody[8..msgBody.length-1];
            }
        }

        sendChatMessage(channel, actualNickname, msgBody, isAction);
    }

    override void onDirectMessage(Message fullMessage, string nickname, string msgBody) {
        bool isAction = false;
        if (msgBody.length > 0 && msgBody[0] == '\x01' && msgBody.endsWith("\x01")) {
            if (msgBody.length >= 8 && msgBody[1..8] == "ACTION ") {
                isAction = true;
                msgBody = msgBody[8..msgBody.length-1];
            }
        }

        sendChatMessage("", nickname, msgBody, isAction);
    }

    void onNoticeMessage(Message fullMessage, string target, string msgBody) {
        string sender = fullMessage.getFrom();
        string nickname = sender;
        auto exclamation = sender.indexOf("!");
        if (exclamation != -1) {
            nickname = sender[0..exclamation];
        }

        string channel = target;
        if (channel.length > 0 && channel[0] == ':') {
            channel = channel[1..$];
        }

        sendChatMessage(channel, nickname, msgBody, false, true);
    }

    override void onGenericCommand(Message message) {
        string cmd = message.getCommand();
        string params = message.getParams();
        string trailing = message.getTrailing();

        if (cmd == "JOIN") {
            string channel = params;
            if (channel.length > 0 && channel[0] == ':') {
                channel = channel[1..$];
            }

            string sender = message.getFrom();
            string nickname = sender;
            auto exclamation = sender.indexOf("!");
            if (exclamation != -1) {
                nickname = sender[0..exclamation];
            }

            string actualNickname = nickname;
            if (nickname.length > 0 && (nickname[0] == '@' || nickname[0] == '+' ||
                nickname[0] == '%' || nickname[0] == '&' || nickname[0] == '~')) {
                actualNickname = nickname[1..$];
                char prefixChar = nickname[0];
                string[] modeParams = [actualNickname];
                tracker.onMode(channel, "+" ~ [prefixChar].idup, modeParams);
            }

            logToTerminal(actualNickname ~ " joined " ~ channel, "INFO", "irc");

            tracker.onJoin(channel, actualNickname);

            if (actualNickname == defaultNick) {
                sendSystemMessage("Successfully joined " ~ channel);
                sendChannelUpdate(channel, "join");
            } else {
                sendChatMessage(channel, actualNickname, "joined the channel", false, false, "join");
            }
        }
        else if (cmd == "PART") {
            string channel = params;
            if (channel.length > 0 && channel[0] == ':') {
                channel = channel[1..$];
            }

            string sender = message.getFrom();
            string nickname = sender;
            auto exclamation = sender.indexOf("!");
            if (exclamation != -1) {
                nickname = sender[0..exclamation];
            }

            string actualNickname = nickname;
            if (nickname.length > 0 && (nickname[0] == '@' || nickname[0] == '+' ||
                nickname[0] == '%' || nickname[0] == '&' || nickname[0] == '~')) {
                actualNickname = nickname[1..$];
            }

            string partMsg = trailing.length > 0 ? trailing : "";
            logToTerminal(actualNickname ~ " left " ~ channel, "INFO", "irc");

            tracker.onPart(channel, actualNickname);

            if (actualNickname == defaultNick) {
                sendChannelUpdate(channel, "part");
            } else {
                string msgText = "left the channel";
                if (partMsg.length > 0) {
                    msgText ~= " (" ~ partMsg ~ ")";
                }
                sendChatMessage(channel, actualNickname, msgText, false, false, "part");
            }
        }
        else if (cmd == "QUIT") {
            string sender = message.getFrom();
            string nickname = sender;
            auto exclamation = sender.indexOf("!");
            if (exclamation != -1) {
                nickname = sender[0..exclamation];
            }

            string actualNickname = nickname;
            if (nickname.length > 0 && (nickname[0] == '@' || nickname[0] == '+' ||
                nickname[0] == '%' || nickname[0] == '&' || nickname[0] == '~')) {
                actualNickname = nickname[1..$];
            }

            string quitMsg = trailing.length > 0 ? trailing : "";
            logToTerminal(actualNickname ~ " quit: " ~ quitMsg, "INFO", "irc");

            tracker.onQuit(actualNickname);

            string msgText = "quit";
            if (quitMsg.length > 0) {
                msgText ~= ": " ~ quitMsg;
            }
            sendChatMessage("", actualNickname, msgText, false, false, "quit");
        }
        else if (cmd == "NICK") {
            string sender = message.getFrom();
            string oldNick = sender;
            auto exclamation = sender.indexOf("!");
            if (exclamation != -1) {
                oldNick = sender[0..exclamation];
            }

            string actualOldNick = oldNick;
            if (oldNick.length > 0 && (oldNick[0] == '@' || oldNick[0] == '+' ||
                oldNick[0] == '%' || oldNick[0] == '&' || oldNick[0] == '~')) {
                actualOldNick = oldNick[1..$];
            }

            string newNick = trailing;
            if (newNick.length > 0 && newNick[0] == ':') {
                newNick = newNick[1..$];
            }

            logToTerminal(actualOldNick ~ " is now known as " ~ newNick, "INFO", "irc");

            tracker.onNickChange(actualOldNick, newNick);
            sendChatMessage("", actualOldNick, "is now known as " ~ newNick, false, false, "nick");
        }
        else if (cmd == "MODE") {
            auto parts = params.split(" ");
            if (parts.length >= 2) {
                string target = parts[0];
                if (target.length > 0 && target[0] == '#') {
                    string channel = target;
                    string modeStr = parts[1];

                    string[] modeParams;
                    if (parts.length > 2) {
                        modeParams = parts[2..$];
                    }

                    if (trailing.length > 0 && modeParams.length == 0) {
                        modeParams = [trailing];
                    } else if (trailing.length > 0) {
                        modeParams ~= trailing;
                    }

                    foreach (ref param; modeParams) {
                        if (param.length > 0 && param[0] == ':') {
                            param = param[1..$];
                        }
                    }

                    tracker.onMode(channel, modeStr, modeParams);
                }
            }
        }
    }

    override void onCommandReply(Message commandReply) {
        string cmd = commandReply.getCommand();
        string params = commandReply.getParams();
        string trailing = commandReply.getTrailing();
        
        logToTerminal("DEBUG onCommandReply: cmd=" ~ cmd ~ " params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");

        try {
            int replyCode = to!int(cmd);

            if (replyCode == 001) {
                logToTerminal("Connected to server", "INFO", "irc");
                sendSystemMessage("Connected to " ~ serverName);
                tracker.setSelfUser(defaultNick);
            }
            else if (replyCode == 311) { // RPL_WHOISUSER
                logToTerminal("DEBUG 311 WHOISUSER: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 4) {
                    // Reset WHOIS state for new WHOIS
                    resetWhoisState();

                    string nickname = parts[1];
                    string user = parts[2];
                    string host = parts[3];
                    string realname = trailing;
                    if (realname.length > 0 && realname[0] == ':') {
                        realname = realname[1..$];
                    }
                    
                    pendingWhoisBuilder = WhoisReplyBuilder(serverName, nickname);
                    pendingWhoisBuilder.user = user;
                    pendingWhoisBuilder.host = host;
                    pendingWhoisBuilder.realname = realname;
                    whoisCurrentTarget = nickname;
                    whoisWaitingForEnd = true;

                    logToTerminal("DEBUG: Started WHOIS for " ~ nickname, "DEBUG", "irc");
                }
            }
            else if (replyCode == 312) { // RPL_WHOISSERVER
                logToTerminal("DEBUG 312 WHOISSERVER: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 3) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string server = parts[2];
                        string serverInfo = trailing;
                        if (serverInfo.length > 0 && serverInfo[0] == ':') {
                            serverInfo = serverInfo[1..$];
                        }
                        pendingWhoisBuilder.serverInfo = "Using server: " ~ server;
                        if (serverInfo.length > 0) {
                            pendingWhoisBuilder.serverInfo ~= " (" ~ serverInfo ~ ")";
                        }
                        logToTerminal("DEBUG: Set serverInfo=" ~ pendingWhoisBuilder.serverInfo, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 313) { // RPL_WHOISOPERATOR
                logToTerminal("DEBUG 313 WHOISOPERATOR: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        pendingWhoisBuilder.isOperator = true;
                        logToTerminal("DEBUG: Set isOperator=true", "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 317) { // RPL_WHOISIDLE
                logToTerminal("DEBUG 317 WHOISIDLE: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 4) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string idleSecondsStr = parts[2];
                        string signonTime = parts[3];
                        pendingWhoisBuilder.idleTime = idleSecondsStr;
                        pendingWhoisBuilder.signonTime = signonTime;
                        logToTerminal("DEBUG: Set idleTime=" ~ idleSecondsStr ~ " signonTime=" ~ signonTime, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 319) { // RPL_WHOISCHANNELS
                logToTerminal("DEBUG 319 WHOISCHANNELS: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string channels = trailing;
                        if (channels.length > 0 && channels[0] == ':') {
                            channels = channels[1..$];
                        }
                        if (channels.length > 0) {
                            pendingWhoisBuilder.channels = channels.split(" ");
                            logToTerminal("DEBUG: Set channels=" ~ channels, "DEBUG", "irc");
                        }
                    }
                }
            }
            else if (replyCode == 301) { // RPL_AWAY
                logToTerminal("DEBUG 301 AWAY: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string awayMsg = trailing;
                        if (awayMsg.length > 0 && awayMsg[0] == ':') {
                            awayMsg = awayMsg[1..$];
                        }
                        pendingWhoisBuilder.isAway = true;
                        pendingWhoisBuilder.awayMessage = awayMsg;
                        logToTerminal("DEBUG: Set away=true message=" ~ awayMsg, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 307) { // RPL_WHOISREGNICK
                logToTerminal("DEBUG 307 WHOISREGNICK: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        pendingWhoisBuilder.isRegistered = true;
                        logToTerminal("DEBUG: Set isRegistered=true", "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 310) { // RPL_WHOISHELPOP
                logToTerminal("DEBUG 310 WHOISHELPOP: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        pendingWhoisBuilder.isHelpOp = true;
                        logToTerminal("DEBUG: Set isHelpOp=true", "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 320) { // RPL_WHOISSPECIAL
                logToTerminal("DEBUG 320 WHOISSPECIAL: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string specialInfo = trailing;
                        if (specialInfo.length > 0 && specialInfo[0] == ':') {
                            specialInfo = specialInfo[1..$];
                        }
                        pendingWhoisBuilder.specialInfo = specialInfo;
                        logToTerminal("DEBUG: Set specialInfo=" ~ specialInfo, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 330) { // RPL_WHOISLOGGEDIN
                logToTerminal("DEBUG 330 WHOISLOGGEDIN: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 3) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string account = parts[2];
                        pendingWhoisBuilder.loggedInAs = account;
                        logToTerminal("DEBUG: Set loggedInAs=" ~ account, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 338) { // RPL_WHOISACTUALLY
                logToTerminal("DEBUG 338 WHOISACTUALLY: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        // The actual host is in params[2] if available
                        string actualInfo = "";
                        if (parts.length >= 3) {
                            actualInfo = parts[2];
                        }
                        
                        // If there's trailing text, append it
                        string trailingText = trailing;
                        if (trailingText.length > 0 && trailingText[0] == ':') {
                            trailingText = trailingText[1..$];
                        }
                        
                        if (actualInfo.length > 0) {
                            if (trailingText.length > 0) {
                                pendingWhoisBuilder.actualHost = actualInfo ~ " (" ~ trailingText ~ ")";
                            } else {
                                pendingWhoisBuilder.actualHost = actualInfo;
                            }
                        } else if (trailingText.length > 0) {
                            pendingWhoisBuilder.actualHost = trailingText;
                        }
                        
                        logToTerminal("DEBUG: Set actualHost=" ~ pendingWhoisBuilder.actualHost, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 378) { // RPL_WHOISHOST
                logToTerminal("DEBUG 378 WHOISHOST: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string hostInfo = trailing;
                        if (hostInfo.length > 0 && hostInfo[0] == ':') {
                            hostInfo = hostInfo[1..$];
                        }
                        pendingWhoisBuilder.hostInfo = hostInfo;
                        logToTerminal("DEBUG: Set hostInfo=" ~ hostInfo, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 379) { // RPL_WHOISMODES
                logToTerminal("DEBUG 379 WHOISMODES: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string modesInfo = trailing;
                        if (modesInfo.length > 0 && modesInfo[0] == ':') {
                            modesInfo = modesInfo[1..$];
                        }
                        pendingWhoisBuilder.modesInfo = modesInfo;
                        logToTerminal("DEBUG: Set modesInfo=" ~ modesInfo, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 671) { // RPL_WHOISSECURE
                logToTerminal("DEBUG 671 WHOISSECURE: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        string secureInfo = trailing;
                        if (secureInfo.length > 0 && secureInfo[0] == ':') {
                            secureInfo = secureInfo[1..$];
                        }
                        pendingWhoisBuilder.secureInfo = secureInfo;
                        logToTerminal("DEBUG: Set secureInfo=" ~ secureInfo, "DEBUG", "irc");
                    }
                }
            }
            else if (replyCode == 318) { // RPL_ENDOFWHOIS
                logToTerminal("DEBUG 318 ENDOFWHOIS: params='" ~ params ~ "' trailing='" ~ trailing ~ "'", "DEBUG", "irc");
                auto parts = params.split(" ");
                if (parts.length >= 2) {
                    string nickname = parts[1];
                    if (whoisWaitingForEnd && nickname == whoisCurrentTarget) {
                        logToTerminal("DEBUG: WHOIS ended for " ~ nickname, "DEBUG", "irc");
                        whoisWaitingForEnd = false;
                        
                        // Wait for any pending replies
                        Thread.sleep(10.msecs);
                        
                        // Send the WHOIS result
                        sendWhoisResult();
                    }
                }
            }
            else if (replyCode == 332) {
                auto parts = params.split(" ");
                if (parts.length >= 3) {
                    string channel = parts[1];
                    if (channel.length > 0 && channel[0] == ':') {
                        channel = channel[1..$];
                    }
                    string topic = trailing;
                    if (topic.length > 0 && topic[0] == ':') {
                        topic = topic[1..$];
                    }
                    sendTopicMessage(channel, topic);
                }
            }
            else if (replyCode == 333) {
                auto parts = params.split(" ");
                if (parts.length >= 4) {
                    string channel = parts[1];
                    if (channel.length > 0 && channel[0] == ':') {
                        channel = channel[1..$];
                    }
                    string setter = parts[2];
                    string timestamp = parts[3];
                }
            }
            else if (replyCode == 353) {
                auto parts = params.split(" ");
                if (parts.length >= 3) {
                    string channel = parts[2];
                    if (channel.length > 0 && channel[0] == ':') {
                        channel = channel[1..$];
                    }

                    auto names = trailing.split(" ");
                    tracker.onNames(channel, names);
                }
            }
            else if (replyCode == 366) {
                // End of NAMES
            }
            // Error replies (4xx-5xx)
            else if (replyCode >= 400 && replyCode <= 599) {
                if (trailing.length > 0) {
                    sendSystemMessage(trailing);
                }
            }
            // Other numeric replies (200-399)
            else if (replyCode >= 200 && replyCode <= 399) {
                if (trailing.length > 0 && replyCode != 353 && replyCode != 366) {
                    sendSystemMessage(trailing);
                }
            }
        } catch (Exception e) {
            logToTerminal("ERROR parsing reply: " ~ e.msg, "ERROR", "irc");
            if (trailing.length > 0) {
                sendSystemMessage(trailing);
            }
        }
    }

    override void onConnectionClosed() {
        logToTerminal("Connection to " ~ serverName ~ " closed", "INFO", "irc");

        sendChannelUpdate("", "failed");
        clientRunning = false;
        if (tracker) {
            tracker.stop();
        }
    }
}

void runIrcServer(string server, Tid gtkTid, int pipeFd) {
    logToTerminal("Creating IRC client for " ~ server, "INFO", "irc");

    try {
        auto client = new MyIRCClient(server, gtkTid, pipeFd);
        client.connect();
        logToTerminal("IRC client connected, waiting for commands...", "INFO", "irc");

        bool running = true;
        while (running && client.clientRunning) {
            bool gotCommand = false;
            bool shouldQuit = false;
            do {
                gotCommand = receiveTimeout(Duration.zero,
                    (IrcFromGtkMessage msg) {
                        try {
                            if (msg.type == IrcFromGtkMessage.Type.Message && msg.text.length > 0) {
                                if (msg.channel.length > 0 && msg.channel[0] == '#') {
                                    bool isAction = false;
                                    string displayText = msg.text;
                                    if (msg.text.length > 0 && msg.text[0] == '\x01' && msg.text.endsWith("\x01")) {
                                        if (msg.text.length >= 8 && msg.text[1..8] == "ACTION ") {
                                            isAction = true;
                                            displayText = msg.text[8..msg.text.length-1];
                                        }
                                    }

                                    client.sendChatMessage(msg.channel, defaultNick, displayText, isAction, false, isAction ? "action" : "message");

                                    client.channelMessage(msg.text, msg.channel);
                                    logToTerminal("Sent to " ~ msg.channel ~ ": " ~ msg.text, "INFO", "irc");
                                } else if (msg.channel.length > 0 && msg.channel[0] != '#') {
                                    bool isAction = false;
                                    string displayText = msg.text;
                                    if (msg.text.length > 0 && msg.text[0] == '\x01' && msg.text.endsWith("\x01")) {
                                        if (msg.text.length >= 8 && msg.text[1..8] == "ACTION ") {
                                            isAction = true;
                                            displayText = msg.text[8..msg.text.length-1];
                                        }
                                    }

                                    string pmText = isAction ? displayText : ("To " ~ msg.channel ~ ": " ~ displayText);
                                    client.sendChatMessage("", defaultNick, pmText, isAction, false, isAction ? "action" : "message");

                                    client.directMessage(msg.text, msg.channel);
                                    logToTerminal("Sent PM to " ~ msg.channel ~ ": " ~ msg.text, "INFO", "irc");
                                } else {
                                    auto spacePos = msg.text.indexOf(" ");
                                    string command;
                                    string params;
                                    if (spacePos != -1) {
                                        command = msg.text[0..spacePos];
                                        params = msg.text[spacePos+1..$];
                                    } else {
                                        command = msg.text;
                                        params = "";
                                    }

                                    auto rawMessage = new Message("", command, params);

                                    client.command(rawMessage);
                                    logToTerminal("Sent raw command: " ~ msg.text, "INFO", "irc");
                                }
                            } else if (msg.type == IrcFromGtkMessage.Type.UpdateChannels) {
                                if (msg.action == "join" && msg.channel.length > 0) {
                                    client.joinChannel(msg.channel);
                                    logToTerminal("Joining " ~ msg.channel, "INFO", "irc");
                                } else if (msg.action == "part" && msg.channel.length > 0) {
                                    client.leaveChannel(msg.channel);
                                    logToTerminal("Leaving " ~ msg.channel, "INFO", "irc");
                                } else if (msg.action == "quit") {
                                    logToTerminal("Quitting IRC", "INFO", "irc");
                                    try {
                                        client.quit();
                                    } catch (Exception e) {
                                        logToTerminal("Error during quit: " ~ e.msg, "DEBUG", "irc");
                                    }
                                    running = false;
                                    shouldQuit = true;
                                } else if (msg.action == "whois" && msg.channel.length > 0) {
                                    client.command(new Message("", "WHOIS", msg.channel));
                                    logToTerminal("WHOIS for " ~ msg.channel, "INFO", "irc");
                                }
                            }
                        } catch (Exception e) {
                            logToTerminal("Error: " ~ e.msg, "ERROR", "irc");
                            client.sendSystemMessage("Error: " ~ e.msg);
                        }
                        return true;
                    }
                );
            } while (gotCommand && !shouldQuit);

            if (shouldQuit) {
                break;
            }

            Thread.sleep(10.msecs);
        }

        logToTerminal("IRC client thread exiting", "INFO", "irc");
    } catch (Exception e) {
        logToTerminal("Error: " ~ e.msg, "ERROR", "irc");
        send(gtkTid, IrcToGtkMessage.fromSystem("Connection error: " ~ e.msg));
    }
}
