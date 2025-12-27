module frontend.lsp.core.dispatch;

import std.json;
import std.conv;
import std.functional : toDelegate;
import core.thread;
import core.atomic;
import frontend.lsp.core.transport;
import infrastructure.utils.logging;

/// Handler function types
alias RequestHandler = JSONValue delegate(JSONValue params);
alias NotificationHandler = void delegate(JSONValue params);

/// Message dispatcher - routes incoming messages to registered handlers
/// Separates message routing from processing logic for testability
final class MessageDispatcher
{
    private RequestHandler[string] requestHandlers;
    private NotificationHandler[string] notificationHandlers;
    private void delegate(JSONValue id, JSONValue result) responseCallback;
    private void delegate(JSONValue id, int code, string msg) errorCallback;
    
    /// Register request handler (method with response)
    @safe void onRequest(string method, RequestHandler handler)
    {
        requestHandlers[method] = handler;
    }
    
    /// Register notification handler (method without response)
    @safe void onNotification(string method, NotificationHandler handler)
    {
        notificationHandlers[method] = handler;
    }
    
    /// Set response callback
    @safe void setResponseCallback(void delegate(JSONValue, JSONValue) cb)
    {
        responseCallback = cb;
    }
    
    /// Set error callback
    @safe void setErrorCallback(void delegate(JSONValue, int, string) cb)
    {
        errorCallback = cb;
    }
    
    /// Dispatch a parsed JSON-RPC message
    @system void dispatch(JSONValue json)
    {
        if ("id" in json)
            dispatchRequest(json);
        else
            dispatchNotification(json);
    }
    
    private void dispatchRequest(JSONValue json) @system
    {
        auto method = json["method"].str;
        auto id = json["id"];
        
        structuredLog.debug_("request_").field("detail", "Request: " ~ method).emit();
        
        if (auto handler = method in requestHandlers)
        {
            try
            {
                auto params = "params" in json ? json["params"] : JSONValue.emptyObject;
                auto result = (*handler)(params);
                if (responseCallback) responseCallback(id, result);
            }
            catch (Exception e)
            {
                structuredLog.error("request_handler_error_").field("detail", "Request handler error: " ~ e.msg).emit();
                if (errorCallback) errorCallback(id, -32603, "Internal error: " ~ e.msg);
            }
        }
        else
        {
            structuredLog.warning("unhandled_request_").field("detail", "Unhandled request: " ~ method).emit();
            if (errorCallback) errorCallback(id, -32601, "Method not found: " ~ method);
        }
    }
    
    private void dispatchNotification(JSONValue json) @system
    {
        auto method = json["method"].str;
        
        structuredLog.debug_("notification_").field("detail", "Notification: " ~ method).emit();
        
        if (auto handler = method in notificationHandlers)
        {
            try
            {
                auto params = "params" in json ? json["params"] : JSONValue.emptyObject;
                (*handler)(params);
            }
            catch (Exception e)
            {
                structuredLog.error("notification_handler_error_").field("detail", "Notification handler error: " ~ e.msg).emit();
            }
        }
        else
        {
            structuredLog.debug_("unhandled_notification_").field("detail", "Unhandled notification: " ~ method).emit();
        }
    }
}

/// Async message loop - processes messages from transport using dispatcher
final class AsyncMessageLoop
{
    private AsyncTransport transport;
    private MessageDispatcher dispatcher;
    private shared bool running;
    private Thread workerThread;
    
    @system this(AsyncTransport t, MessageDispatcher d)
    {
        transport = t;
        dispatcher = d;
        atomicStore(running, false);
        
        // Wire up response/error callbacks to transport
        dispatcher.setResponseCallback(&sendResponse);
        dispatcher.setErrorCallback(&sendError);
    }
    
    /// Start the message loop (blocking on current thread)
    @system void run()
    {
        atomicStore(running, true);
        transport.start();
        
        while (atomicLoad(running) && transport.isActive)
        {
            auto msg = transport.receive();
            if (msg.empty)
            {
                if (!transport.isActive) break;
                continue;
            }
            
            try
            {
                auto json = parseJSON(msg.content);
                dispatcher.dispatch(json);
            }
            catch (JSONException e)
            {
                structuredLog.error("invalid_json_").field("detail", "Invalid JSON: " ~ e.msg).emit();
            }
        }
        
        transport.stop();
        structuredLog.info("message_loop_terminated").emit();
    }
    
    /// Start the message loop in a background thread
    @system void runAsync()
    {
        workerThread = new Thread(&run);
        workerThread.start();
    }
    
    /// Stop the message loop
    @system void stop()
    {
        atomicStore(running, false);
        transport.stop();
        if (workerThread !is null) workerThread.join();
    }
    
    @property @system bool isRunning() const => atomicLoad(running);
    
    private void sendResponse(JSONValue id, JSONValue result) @system
    {
        JSONValue response;
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = result;
        transport.send(response.toString());
    }
    
    private void sendError(JSONValue id, int code, string message) @system
    {
        JSONValue response;
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        
        JSONValue error;
        error["code"] = code;
        error["message"] = message;
        response["error"] = error;
        transport.send(response.toString());
    }
    
    /// Send notification to client
    @system void notify(string method, JSONValue params)
    {
        JSONValue notification;
        notification["jsonrpc"] = "2.0";
        notification["method"] = method;
        notification["params"] = params;
        transport.send(notification.toString());
    }
}


