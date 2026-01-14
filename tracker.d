// source/tracker.d
module tracker;

import std.algorithm : canFind, countUntil;
import std.algorithm.mutation : remove;
import std.array : array;
import std.exception : enforce;
import std.string : toStringz, fromStringz;
import std.stdio;

/// Mode prefix mapping and priority (higher = shown)
private string[char] modeToPrefix;
private int[char] prefixPriority;

shared static this() {
    writefln("TRACKER: Static initializer running");

    // Debug: Show what we're setting
    writefln("TRACKER: Setting modeToPrefix and prefixPriority...");

    modeToPrefix['q'] = "~";  // owner
    modeToPrefix['a'] = "&";  // admin
    modeToPrefix['o'] = "@";  // op
    modeToPrefix['h'] = "%";  // halfop
    modeToPrefix['v'] = "+";  // voice

    prefixPriority['~'] = 5;
    prefixPriority['&'] = 4;
    prefixPriority['@'] = 3;
    prefixPriority['%'] = 2;                                                     prefixPriority['+'] = 1;
                                                                                 // Debug: Verify the dictionaries
    writefln("TRACKER: modeToPrefix contents:");
    foreach (key, value; modeToPrefix) {
        writefln("  '%c' (0x%02x) -> '%s'", key, key, value);
    }

    writefln("TRACKER: prefixPriority contents:");
    foreach (key, value; prefixPriority) {
        writefln("  '%c' (0x%02x) -> %d", key, key, value);
    }

    // Test the lookups
    writefln("TRACKER: Testing lookups:");
    char[] testChars = ['@', '+', '%', '&', '~'];
    foreach (testChar; testChars) {
        auto ptr = testChar in prefixPriority;
        writefln("  '%c' (0x%02x) in prefixPriority: %s", testChar, testChar, ptr !is null);
        if (ptr !is null) {
            writefln("    prefixPriority['%c'] = %d", testChar, *ptr);
        }
    }
}

/// Tracked user with per-channel highest prefix
struct TrackedUser {
    string nick;
    string ident;
    string host;
    string realName;

    string[] channels;

    // channel -> highest prefix char (or '\0' if none)
    char[string] channelPrefix;

    this(string nick, string ident = "", string host = "") {
        this.nick = nick;
        this.ident = ident;
        this.host = host;
    }

    string toString() const {
        import std.format : format;
        return format("%s!%s@%s (%s)", nick, ident, host, channels);
    }
}

/// Tracked channel
struct TrackedChannel {
    string name;
    TrackedUser*[string] users;  // nick -> user pointer

    this(string name) {
        this.name = name;
    }
}

/// Main tracker class
class Tracker {
    private TrackedUser*[string] users;           // nick -> user
    private TrackedChannel[string] channels;      // channel -> channel
    private TrackedUser* selfUser;

    private bool tracking = false;

    this() {
        writefln("TRACKER: Constructor called at address %s", cast(void*)this);
    }

    /// Start tracking (call after connection)
    void start() {
        writefln("TRACKER: start() called, tracking was: %s", tracking);
        if (tracking) return;
        tracking = true;
        writefln("TRACKER: tracking set to true");
    }

    /// Stop and clear all data
    void stop() {
        writefln("TRACKER: stop() called");
        users = null;
        channels = null;
        selfUser = null;
        tracking = false;
    }

    /// Is currently tracking?
    bool isTracking() const @property {
        return tracking;
    }

    /// Find a channel (null if not in it)
    TrackedChannel* findChannel(string channel) {
        enforce(tracking, "Tracker not active");
        return channel in channels;
    }

    /// Find a user by nick
    TrackedUser* findUser(string nick) {
        enforce(tracking, "Tracker not active");
        auto p = nick in users;
        return p ? *p : null;
    }

    /// Get highest prefix for user in channel ('\0' = none)
    char getPrefix(string channel, string nick) const {
        writefln("TRACKER: getPrefix called for nick='%s' in channel='%s'", nick, channel);

        if (auto userPtr = nick in users) {
            auto user = *userPtr;

            if (auto p = channel in user.channelPrefix) {
                writefln("TRACKER: Found prefix '%c' for '%s' in '%s'", *p, nick, channel);
                return *p;
            }
        }
        writefln("TRACKER: No prefix found for '%s' in '%s'", nick, channel);
        return '\0';
    }

    // ==================== Event Handlers ====================

    void onSelfNick(string newNick) {
        if (selfUser) {
            selfUser.nick = newNick;
        }
    }

    void onJoin(string channel, string nick, string ident = "", string host = "") {
        TrackedUser* user;

        if (selfUser && nick == selfUser.nick) {  // self join
            user = selfUser;
        } else if (auto p = nick in users) {
            user = *p;
        } else {
            user = new TrackedUser(nick, ident, host);
            users[nick] = user;
        }

        if (!user.channels.canFind(channel)) {
            user.channels ~= channel;
        }

        if (channel !in channels) {
            channels[channel] = TrackedChannel(channel);
        }

        channels[channel].users[nick] = user;
    }

    void onNames(string channel, string[] nicks) {
        writefln("TRACKER: onNames called for channel='%s' with %d nicks", channel, nicks.length);

        // CRITICAL DEBUG: Check if prefixPriority is accessible
        writefln("TRACKER: Checking module-level prefixPriority from class method:");
        writefln("  Address of prefixPriority: %p", &prefixPriority);
        writefln("  Length of prefixPriority: %d", prefixPriority.length);

        // Check each known prefix character
        char[] testChars = ['@', '+', '%', '&', '~'];
        foreach (testChar; testChars) {
            auto ptr = testChar in prefixPriority;
            writefln("  '%c' (0x%02x) in prefixPriority: %s", testChar, testChar, ptr !is null);
            if (ptr !is null) {
                writefln("    prefixPriority['%c'] = %d", testChar, *ptr);
            }
        }

        if (channel !in channels) {
            channels[channel] = TrackedChannel(channel);
        }

        foreach (rawNick; nicks) {
            writefln("TRACKER: Processing rawNick='%s'", rawNick);

            // Strip prefix from NAMES (some servers send @nick, +nick)
            string nick = rawNick;
            char prefix = '\0';

            if (rawNick.length > 0) {
                char first = rawNick[0];
                writefln("  First char: '%c' (0x%02x)", first, first);

                // DIRECT TEST: Try to access prefixPriority directly
                bool found = false;
                foreach (key, value; prefixPriority) {
                    if (key == first) {
                        found = true;
                        writefln("  FOUND in prefixPriority by iteration: key='%c', value=%d", key, value);
                        break;
                    }
                }

                if (found) {
                    prefix = first;
                    nick = rawNick[1..$];
                    writefln("  Extracted prefix '%c', nick is now '%s'", prefix, nick);
                } else {
                    writefln("  Not found in prefixPriority");
                }
            }

            TrackedUser* user;
            if (auto p = nick in users) {
                user = *p;
            } else {
                user = new TrackedUser(nick);
                users[nick] = user;
            }

            if (!user.channels.canFind(channel)) {
                user.channels ~= channel;
            }

            channels[channel].users[nick] = user;

            // Apply prefix from NAMES if present
            if (prefix != '\0') {
                user.channelPrefix[channel] = prefix;
                writefln("  Set prefix '%c' for '%s' in '%s'", prefix, nick, channel);
            }
        }
    }

    void onPart(string channel, string nick) {
        if (auto chan = channel in channels) {
            chan.users.remove(nick);

            if (auto userPtr = nick in users) {
                auto user = *userPtr;
                auto idx = user.channels.countUntil(channel);
                if (idx != -1) {
                    user.channels = user.channels.remove(idx);
                }
                user.channelPrefix.remove(channel);

                if (user.channels.length == 0 && user != selfUser) {
                    users.remove(nick);
                }
            }

            if (chan.users.length == 0) {
                channels.remove(channel);
            }
        }
    }

    void onQuit(string nick) {
        if (auto userPtr = nick in users) {
            auto user = *userPtr;
            foreach (chan; user.channels.dup) {
                onPart(chan, nick);
            }
        }
    }

    void onNickChange(string oldNick, string newNick) {
        if (auto userPtr = oldNick in users) {
            auto user = *userPtr;
            users.remove(oldNick);
            user.nick = newNick;
            users[newNick] = user;

            if (user == selfUser) {
                selfUser = user;
            }

            foreach (chanName; user.channels) {
                if (auto chan = chanName in channels) {
                    chan.users.remove(oldNick);
                    chan.users[newNick] = user;
                }
            }
        }
    }

    void onMode(string channel, string modeStr, string[] params) {
        if (channel.length == 0 || channel[0] != '#') return;

        size_t paramIdx = 0;
        bool adding = true;

        foreach (char c; modeStr) {
            if (c == '+') { adding = true; continue; }
            if (c == '-') { adding = false; continue; }

            if ((c in modeToPrefix) && paramIdx < params.length) {
                string target = params[paramIdx++];
                string prefixStr = modeToPrefix[c];
                char prefix = prefixStr[0];

                if (auto chan = channel in channels) {
                    if (auto userPtr = target in chan.users) {
                        auto user = *userPtr;

                        char current = (channel in user.channelPrefix) ? user.channelPrefix[channel] : '\0';
                        int curPrio = current == '\0' ? 0 : prefixPriority[current];
                        int newPrio = prefixPriority[prefix];

                        if (adding && newPrio > curPrio) {
                            user.channelPrefix[channel] = prefix;
                        } else if (!adding && current == prefix) {
                            user.channelPrefix.remove(channel);
                        }
                    }
                }
            }
        }
    }

    // Call when you know your own nick after connect
    void setSelfUser(string nick, string ident = "", string host = "") {
        selfUser = new TrackedUser(nick, ident, host);
        users[nick] = selfUser;
    }
}
