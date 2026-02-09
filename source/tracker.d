// source/tracker.d
module tracker;

import std.algorithm : canFind, countUntil;
import std.algorithm.mutation : remove;
import std.array : array;
import std.exception : enforce;
import std.format : format;
import std.string : toStringz, fromStringz, toUpper;
import std.stdio;

/// Mode prefix mapping and priority (higher = shown)
private immutable int[char] prefixPriority = [
    '@': 3,
    '+': 1,
    '%': 2,
    '&': 4,
    '~': 5
];

// Mode to prefix mapping
private immutable char[char] modeToPrefix = [
    'q': '~',
    'a': '&',
    'o': '@',
    'h': '%',
    'v': '+'
];

/// Tracked user with all mode flags per channel
struct TrackedUser {
    string nick;
    string ident;
    string host;
    string realName;
    
    string[] channels;
    
    // channel -> array of all prefix chars user has in that channel
    char[][string] channelPrefixes;
    
    this(string nick, string ident = "", string host = "") {
        this.nick = nick;
        this.ident = ident;
        this.host = host;
    }
    
    /// Get highest priority prefix for display
    char getHighestPrefix(string channel) const {
        if (auto prefixesPtr = channel in channelPrefixes) {
            char highest = '\0';
            int highestPrio = 0;
            
            foreach (prefix; *prefixesPtr) {
                int prio = prefixPriority[prefix];
                if (prio > highestPrio) {
                    highest = prefix;
                    highestPrio = prio;
                }
            }
            
            return highest;
        }
        return '\0';
    }
    
    /// Check if user has a specific prefix in channel
    bool hasPrefix(string channel, char prefix) const {
        if (auto prefixesPtr = channel in channelPrefixes) {
            return canFind(*prefixesPtr, prefix);
        }
        return false;
    }
    
    /// Add a prefix to user in channel
    void addPrefix(string channel, char prefix) {
        if (!(channel in channelPrefixes)) {
            channelPrefixes[channel] = [];
        }
        
        if (!hasPrefix(channel, prefix)) {
            channelPrefixes[channel] ~= prefix;
        }
    }
    
    /// Remove a prefix from user in channel
    void removePrefix(string channel, char prefix) {
        if (auto prefixesPtr = channel in channelPrefixes) {
            char[] prefixes = *prefixesPtr;
            char[] newPrefixes;
            
            foreach (p; prefixes) {
                if (p != prefix) {
                    newPrefixes ~= p;
                }
            }
            
            channelPrefixes[channel] = newPrefixes;
            
            if (newPrefixes.length == 0) {
                channelPrefixes.remove(channel);
            }
        }
    }
    
    /// Get all prefixes user has in channel
    char[] getAllPrefixes(string channel) const {
        if (auto prefixesPtr = channel in channelPrefixes) {
            return (*prefixesPtr).dup;
        }
        return [];
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
    
    /// Start tracking (call after connection)
    void start() {
        if (tracking) return;
        tracking = true;
    }
    
    /// Stop and clear all data
    void stop() {
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
        if (auto userPtr = nick in users) {
            auto user = *userPtr;
            return user.getHighestPrefix(channel);
        } else {
            // Try case-insensitive search
            foreach (storedNick, userPtr; users) {
                if (toUpper(storedNick) == toUpper(nick)) {
                    auto user = *userPtr;
                    return user.getHighestPrefix(channel);
                }
            }
        }
        
        return '\0';
    }
    
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
        if (channel !in channels) {
            channels[channel] = TrackedChannel(channel);
        }
        
        foreach (rawNick; nicks) {
            // Strip prefix from NAMES (some servers send @nick, +nick)
            string nick = rawNick;
            char prefix = '\0';
            
            if (rawNick.length > 0) {
                char first = rawNick[0];
                auto ptr = first in prefixPriority;
                if (ptr !is null) {
                    prefix = first;
                    nick = rawNick[1..$];
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
                user.addPrefix(channel, prefix);
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
                
                // Remove all prefixes for this channel
                user.channelPrefixes.remove(channel);
                
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
            
            // Check if this is a prefix mode
            if (c in modeToPrefix) {
                char prefix = modeToPrefix[c];
                
                // Get target user
                string target;
                if (paramIdx < params.length) {
                    target = params[paramIdx];
                    paramIdx++;
                } else {
                    // No more parameters, use last one
                    if (params.length > 0) {
                        target = params[params.length - 1];
                    } else {
                        continue;
                    }
                }
                
                if (auto chan = channel in channels) {
                    if (auto userPtr = target in chan.users) {
                        auto user = *userPtr;
                        
                        if (adding) {
                            // Add the prefix
                            user.addPrefix(channel, prefix);
                        } else {
                            // Remove the prefix
                            user.removePrefix(channel, prefix);
                        }
                    }
                }
            } else {
                // Non-prefix mode - advance parameter index
                if (paramIdx < params.length) {
                    paramIdx++;
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
