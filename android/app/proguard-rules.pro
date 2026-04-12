# Apache MINA SSHD
-keep class org.apache.sshd.** { *; }
-dontwarn org.apache.sshd.**
-dontwarn org.slf4j.**

# gomobile-generated Tailscale bridge
-keep class gobridge.** { *; }
-keep class go.** { *; }
