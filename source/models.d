// source/models.d
module models;

import std.stdio;
import std.conv;
import std.datetime;
import std.string;
import std.array;
import std.algorithm;

immutable string defaultChannel = "#pike-test";
immutable string defaultServer = "irc.deft.com";
immutable ushort defaultPort = 6667;
immutable string defaultNick = "x2bncwn";

/// Types of messages sent from the IRC thread to the GTK thread
enum IrcToGtkType {
    chatMessage,
    channelUpdate,
    systemMessage,
    channelTopic
}

/// Structured chat message with separate raw nick and prefix
struct ChatMessage {
    string server;
    string channel;
    string timestamp;
    string rawNick;
    string prefix;
    string messageType;
    string body;
}

/// Channel join/part/failed update
struct ChannelUpdate {
    string server;
    string channel;
    string action;
}

/// Channel topic update
struct ChannelTopic {
    string server;
    string channel;
    string topic;
}

/// Builder for constructing immutable WhoIsReply
struct WhoisReplyBuilder {
    string server;
    string target;
    string user;
    string host;
    string realname;
    string serverInfo;
    string[] channels;
    bool isOperator;
    bool isRegistered;
    bool isHelpOp;
    bool isAway;
    string awayMessage;
    string loggedInAs;
    string actualHost;
    string idleTime;
    string signonTime;
    string secureInfo;
    string hostInfo;
    string modesInfo;
    string specialInfo;

    this(string server, string target) {
        this.server = server;
        this.target = target;
        this.channels = [];
    }
}

/// Immutable WHOIS reply data
struct WhoisReply {
    // All fields immutable - set once during construction
    immutable string server;
    immutable string target;
    immutable string user;
    immutable string host;
    immutable string realname;
    immutable string serverInfo;
    immutable string[] channels;
    immutable bool isOperator;
    immutable bool isRegistered;
    immutable bool isHelpOp;
    immutable bool isAway;
    immutable string awayMessage;
    immutable string loggedInAs;
    immutable string actualHost;
    immutable string idleTime;
    immutable string signonTime;
    immutable string secureInfo;
    immutable string hostInfo;
    immutable string modesInfo;
    immutable string specialInfo;

    // Constructor from builder
    this(WhoisReplyBuilder builder) {
        this.server = builder.server;
        this.target = builder.target;
        this.user = builder.user;
        this.host = builder.host;
        this.realname = builder.realname;
        this.serverInfo = builder.serverInfo;
        // Convert mutable string[] to immutable string[] using .idup
        this.channels = builder.channels.idup;
        this.isOperator = builder.isOperator;
        this.isRegistered = builder.isRegistered;
        this.isHelpOp = builder.isHelpOp;
        this.isAway = builder.isAway;
        this.awayMessage = builder.awayMessage;
        this.loggedInAs = builder.loggedInAs;
        this.actualHost = builder.actualHost;
        this.idleTime = builder.idleTime;
        this.signonTime = builder.signonTime;
        this.secureInfo = builder.secureInfo;
        this.hostInfo = builder.hostInfo;
        this.modesInfo = builder.modesInfo;
        this.specialInfo = builder.specialInfo;
    }

    // Helper to check if we have basic info
    bool hasBasicInfo() const pure {
        return user.length > 0 && host.length > 0;
    }

    // Helper to format duration
    private string formatDuration(int seconds) const pure {
        if (seconds < 60) {
            return to!string(seconds) ~ " second" ~ (seconds == 1 ? "" : "s");
        } else if (seconds < 3600) {
            int minutes = seconds / 60;
            return to!string(minutes) ~ " minute" ~ (minutes == 1 ? "" : "s");
        } else if (seconds < 86400) {
            int hours = seconds / 3600;
            return to!string(hours) ~ " hour" ~ (hours == 1 ? "" : "s");
        } else {
            int days = seconds / 86400;
            return to!string(days) ~ " day" ~ (days == 1 ? "" : "s");
        }
    }

    // Helper to format signon time
    private string formatSignonTime(string signonTime) const {
        try {
            long timestamp = to!long(signonTime);
            auto signonDate = SysTime.fromUnixTime(timestamp);
            return to!string(signonDate) ~ " UTC";
        } catch (Exception e) {
            return signonTime;
        }
    }

    // Format the WHOIS reply as a string for display
    string format() const {
        string result = "--- WHOIS for " ~ target ~ " ---\n";

        if (hasBasicInfo()) {
            result ~= target ~ " [" ~ user ~ "@" ~ host ~ "] " ~ realname ~ "\n";
        }

        if (serverInfo.length > 0) {
            result ~= serverInfo ~ "\n";
        }

        if (channels.length > 0) {
            result ~= "Channels: " ~ channels.join(" ") ~ "\n";
        }

        if (idleTime.length > 0) {
            try {
                int idleSeconds = to!int(idleTime);
                result ~= "Idle: " ~ formatDuration(idleSeconds) ~ "\n";
            } catch (Exception e) {
                result ~= "Idle: " ~ idleTime ~ "\n";
            }
        }

        if (signonTime.length > 0) {
            result ~= "Signed on: " ~ formatSignonTime(signonTime) ~ "\n";
        }

        if (isOperator) {
            result ~= "This user is an IRC operator\n";
        }

        if (isRegistered) {
            result ~= "Registered nickname\n";
        }

        if (isHelpOp) {
            result ~= "Available for help\n";
        }

        if (isAway && awayMessage.length > 0) {
            result ~= "Away: " ~ awayMessage ~ "\n";
        }

        if (loggedInAs.length > 0) {
            result ~= "Logged in as: " ~ loggedInAs ~ "\n";
        }

        if (actualHost.length > 0) {
            result ~= "Actually: " ~ actualHost ~ "\n";
        }

        if (secureInfo.length > 0) {
            result ~= target ~ " " ~ secureInfo ~ "\n";
        }

        if (hostInfo.length > 0) {
            result ~= "Host info: " ~ hostInfo ~ "\n";
        }

        if (modesInfo.length > 0) {
            result ~= "Modes: " ~ modesInfo ~ "\n";
        }

        if (specialInfo.length > 0) {
            result ~= "Special: " ~ specialInfo ~ "\n";
        }

        result ~= "--- End of WHOIS ---";
        return result;
    }
}

/// Union of all messages sent to GTK
struct IrcToGtkMessage {
    IrcToGtkType type;
    
    union {
        ChatMessage chat;
        ChannelUpdate channelUpdate;
        ChannelTopic topicData;
        string systemText;
    }
    
    // Factory methods
    static IrcToGtkMessage fromChat(ChatMessage c) {
        IrcToGtkMessage m;
        m.type = IrcToGtkType.chatMessage;
        m.chat = c;
        return m;
    }

    static IrcToGtkMessage fromUpdate(ChannelUpdate u) {
        IrcToGtkMessage m;
        m.type = IrcToGtkType.channelUpdate;
        m.channelUpdate = u;
        return m;
    }

    static IrcToGtkMessage fromSystem(string text) {
        IrcToGtkMessage m;
        m.type = IrcToGtkType.systemMessage;
        m.systemText = text;
        return m;
    }

    static IrcToGtkMessage fromTopic(ChannelTopic t) {
        IrcToGtkMessage m;
        m.type = IrcToGtkType.channelTopic;
        m.topicData = t;
        return m;
    }
}

/// Messages from GTK to IRC thread
struct IrcFromGtkMessage {
    enum Type {
        Message,
        UpdateChannels,
        channelTopic
    }
    
    Type type;
    string channel;
    string text;
    string action;
}
