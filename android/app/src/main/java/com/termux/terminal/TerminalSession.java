package com.termux.terminal;

import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.util.Log;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * SSH-backed TerminalSession. Replaces Termux's PTY-based session.
 * Bridges SSH I/O streams to TerminalEmulator.
 */
public class TerminalSession extends TerminalOutput {

    private static final int MSG_NEW_INPUT = 1;
    private static final int MSG_PROCESS_EXITED = 4;

    private String mTitle;
    private TerminalEmulator mEmulator;
    private final TerminalSessionClient mClient;
    private OutputStream mOutputStream;
    private volatile boolean mRunning = false;
    private final ExecutorService mWriteExecutor = Executors.newSingleThreadExecutor();

    private final ByteQueue mProcessToTerminalIOQueue = new ByteQueue(4096);

    private final Handler mMainThreadHandler = new Handler(Looper.getMainLooper()) {
        final byte[] mReceiveBuffer = new byte[4 * 1024];

        @Override
        public void handleMessage(Message msg) {
            if (msg.what == MSG_NEW_INPUT && mEmulator != null) {
                int bytesRead = mProcessToTerminalIOQueue.read(mReceiveBuffer, false);
                if (bytesRead > 0) {
                    Log.d("Handoff", "Handler append " + bytesRead + " bytes");
                    mEmulator.append(mReceiveBuffer, bytesRead);
                    notifyScreenUpdate();
                }
            } else if (msg.what == MSG_PROCESS_EXITED) {
                // SSH disconnected
            }
        }
    };

    public TerminalSession(TerminalSessionClient client) {
        mClient = client;
        mTitle = "SSH";
    }

    /** Initialize the emulator. Must be called before attachSession on TerminalView. */
    public void initializeEmulator(int columns, int rows, int cellWidth, int cellHeight) {
        mEmulator = new TerminalEmulator(this, columns, rows, cellWidth, cellHeight, 5000, mClient);
    }

    /** Start reading SSH output in a background thread. */
    public void startReading(InputStream inputStream) {
        mRunning = true;
        new Thread("SshReader") {
            @Override
            public void run() {
                byte[] buf = new byte[4096];
                try {
                    while (mRunning) {
                        int n = inputStream.read(buf);
                        if (n <= 0) {
                            Log.d("Handoff", "SSH stream ended: n=" + n);
                            break;
                        }
                        Log.d("Handoff", "SSH read " + n + " bytes");
                        mProcessToTerminalIOQueue.write(buf, 0, n);
                        mMainThreadHandler.sendEmptyMessage(MSG_NEW_INPUT);
                    }
                } catch (Exception e) {
                    Log.e("Handoff", "SSH reader error: " + e.getMessage());
                }
                mRunning = false;
                mMainThreadHandler.sendEmptyMessage(MSG_PROCESS_EXITED);
            }
        }.start();
    }

    /** Set the SSH output stream for sending keyboard input. */
    public void setOutputStream(OutputStream os) {
        mOutputStream = os;
    }

    /** Called by TerminalEmulator when data needs to be sent (keyboard input). */
    @Override
    public void write(byte[] data, int offset, int count) {
        OutputStream os = mOutputStream;
        if (os == null) {
            Log.w("Handoff", "write: no output stream!");
            return;
        }
        // Copy data since the caller may reuse the buffer
        byte[] copy = new byte[count];
        System.arraycopy(data, offset, copy, 0, count);
        Log.d("Handoff", "write " + count + " bytes to SSH");
        mWriteExecutor.execute(() -> {
            try {
                os.write(copy, 0, copy.length);
                os.flush();
            } catch (Exception e) {
                Log.e("Handoff", "TerminalSession.write failed: " + e.getMessage());
            }
        });
    }

    /** Write a unicode code point (called by TerminalView for keyboard input). */
    public void writeCodePoint(boolean prependEscape, int codePoint) {
        if (codePoint > 0xFFFF) {
            byte[] bytes = new String(Character.toChars(codePoint)).getBytes(StandardCharsets.UTF_8);
            if (prependEscape) write(new byte[]{27}, 0, 1);
            write(bytes, 0, bytes.length);
        } else {
            byte[] bytes;
            if (prependEscape) {
                bytes = new byte[]{27, (byte) codePoint};
            } else {
                bytes = new byte[]{(byte) codePoint};
            }
            write(bytes, 0, bytes.length);
        }
    }

    public TerminalEmulator getEmulator() {
        return mEmulator;
    }

    public boolean isRunning() {
        return mRunning;
    }

    /** Called by TerminalView.updateSize() when the view dimensions change. */
    public void updateSize(int columns, int rows, int fontWidth, int fontHeight) {
        if (mEmulator != null) {
            mEmulator.resize(columns, rows, fontWidth, fontHeight);
        }
    }

    public String getTitle() {
        return mTitle;
    }

    public void finishIfRunning() {
        mRunning = false;
    }

    @Override
    public void titleChanged(String oldTitle, String newTitle) {
        mTitle = newTitle;
        if (mClient != null) mClient.onTitleChanged(this);
    }

    @Override
    public void onCopyTextToClipboard(String text) {
        if (mClient != null) mClient.onCopyTextToClipboard(this, text);
    }

    @Override
    public void onPasteTextFromClipboard() {
        if (mClient != null) mClient.onPasteTextFromClipboard(this);
    }

    @Override
    public void onBell() {
        if (mClient != null) mClient.onBell(this);
    }

    @Override
    public void onColorsChanged() {
        if (mClient != null) mClient.onColorsChanged(this);
    }

    public void reset() {
        if (mEmulator != null) mEmulator.reset();
        notifyScreenUpdate();
    }

    private void notifyScreenUpdate() {
        if (mClient != null) mClient.onTextChanged(this);
    }
}
