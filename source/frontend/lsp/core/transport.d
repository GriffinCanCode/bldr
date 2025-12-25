module frontend.lsp.core.transport;

import core.thread;
import core.sync.mutex;
import core.sync.condition;
import core.atomic;
import std.stdio;
import std.conv;
import std.string;
import std.algorithm : canFind;
import infrastructure.utils.logging.logger;

/// LSP message with content and metadata
struct LSPMessage
{
    string content;
    bool isRequest;  // True if has ID (requires response)
    
    @property bool empty() const pure nothrow @nogc => content.length == 0;
}

/// Thread-safe message queue for async LSP communication
/// Uses producer-consumer pattern with condition variables for efficient blocking
final class MessageQueue
{
    private LSPMessage[] buffer;
    private size_t head, tail, count;
    private immutable size_t capacity;
    private Mutex mutex;
    private Condition notEmpty;
    private Condition notFull;
    private shared bool closed;
    
    @system this(size_t cap = 256)
    {
        capacity = cap;
        buffer.length = cap;
        mutex = new Mutex();
        notEmpty = new Condition(mutex);
        notFull = new Condition(mutex);
        atomicStore(closed, false);
    }
    
    /// Enqueue message (producer side) - blocks if full
    @system bool enqueue(LSPMessage msg)
    {
        synchronized (mutex)
        {
            while (count >= capacity && !atomicLoad(closed))
                notFull.wait();
            
            if (atomicLoad(closed)) return false;
            
            buffer[tail] = msg;
            tail = (tail + 1) % capacity;
            count++;
            notEmpty.notify();
            return true;
        }
    }
    
    /// Dequeue message (consumer side) - blocks if empty
    @system LSPMessage dequeue()
    {
        synchronized (mutex)
        {
            while (count == 0 && !atomicLoad(closed))
                notEmpty.wait();
            
            if (count == 0) return LSPMessage.init;
            
            auto msg = buffer[head];
            head = (head + 1) % capacity;
            count--;
            notFull.notify();
            return msg;
        }
    }
    
    /// Try dequeue without blocking
    @system LSPMessage tryDequeue()
    {
        synchronized (mutex)
        {
            if (count == 0) return LSPMessage.init;
            
            auto msg = buffer[head];
            head = (head + 1) % capacity;
            count--;
            notFull.notify();
            return msg;
        }
    }
    
    /// Close queue and wake all waiters
    @system void close()
    {
        synchronized (mutex)
        {
            atomicStore(closed, true);
            notEmpty.notifyAll();
            notFull.notifyAll();
        }
    }
    
    @property @system bool isClosed() const => atomicLoad(closed);
    @property @system size_t length() const { synchronized (cast()mutex) return count; }
    @property @system bool empty() const { synchronized (cast()mutex) return count == 0; }
}

/// Async stdio reader thread
/// Reads LSP messages from stdin and enqueues them
final class StdioReader
{
    private MessageQueue queue;
    private Thread thread;
    private shared bool running;
    
    @system this(MessageQueue q)
    {
        queue = q;
        atomicStore(running, false);
    }
    
    @system void start()
    {
        atomicStore(running, true);
        thread = new Thread(&readLoop);
        thread.start();
    }
    
    @system void stop()
    {
        atomicStore(running, false);
        queue.close();
        if (thread !is null) thread.join();
    }
    
    @property @system bool isRunning() const => atomicLoad(running);
    
    private void readLoop() @system
    {
        while (atomicLoad(running))
        {
            try
            {
                auto msg = readMessage();
                if (msg.empty)
                {
                    atomicStore(running, false);
                    break;
                }
                if (!queue.enqueue(msg))
                    break;
            }
            catch (Exception e)
            {
                Logger.error("StdioReader error: " ~ e.msg);
            }
        }
        queue.close();
    }
    
    /// Read single LSP message from stdin (JSON-RPC format)
    private LSPMessage readMessage() @system
    {
        int contentLength;
        string line;
        
        // Read headers
        while ((line = readln()) !is null)
        {
            line = line.strip();
            if (line.length == 0) break;
            
            if (line.startsWith("Content-Length: "))
                contentLength = line["Content-Length: ".length .. $].strip().to!int;
        }
        
        if (contentLength == 0)
            return LSPMessage.init;
        
        // Read content
        char[] buf = new char[contentLength];
        stdin.rawRead(buf);
        
        auto content = cast(string)buf;
        return LSPMessage(content, content.canFind(`"id":`));
    }
}

/// Async stdio writer
/// Thread-safe writes to stdout
final class StdioWriter
{
    private Mutex mutex;
    
    @system this() { mutex = new Mutex(); }
    
    /// Write LSP message to stdout (thread-safe)
    @system void write(string content)
    {
        synchronized (mutex)
        {
            auto out_ = stdout.lockingTextWriter();
            out_.put("Content-Length: ");
            out_.put(content.length.to!string);
            out_.put("\r\n\r\n");
            out_.put(content);
            stdout.flush();
        }
    }
}

/// Async LSP transport combining reader, writer, and message queues
final class AsyncTransport
{
    private MessageQueue inbound;   // Messages from client
    private StdioReader reader;
    private StdioWriter writer;
    private shared bool active;
    
    @system this(size_t queueSize = 256)
    {
        inbound = new MessageQueue(queueSize);
        reader = new StdioReader(inbound);
        writer = new StdioWriter();
        atomicStore(active, false);
    }
    
    /// Start async transport
    @system void start()
    {
        atomicStore(active, true);
        reader.start();
        Logger.info("Async LSP transport started");
    }
    
    /// Stop async transport
    @system void stop()
    {
        atomicStore(active, false);
        reader.stop();
        Logger.info("Async LSP transport stopped");
    }
    
    /// Receive next message (blocks until available)
    @system LSPMessage receive() => inbound.dequeue();
    
    /// Try receive without blocking
    @system LSPMessage tryReceive() => inbound.tryDequeue();
    
    /// Send response/notification
    @system void send(string content) { writer.write(content); }
    
    @property @system bool isActive() const => atomicLoad(active) && reader.isRunning;
    @property @system size_t pendingCount() const => inbound.length;
}


