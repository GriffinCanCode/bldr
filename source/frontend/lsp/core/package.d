/**
 * LSP Core Module
 * 
 * This module contains the core LSP server implementation, including:
 * - LSP server with async message loop (JSON-RPC 2.0 protocol over stdio)
 * - Async transport layer (message queue, stdio reader/writer)
 * - Message dispatcher for routing requests/notifications
 * - LSP protocol types and structures (Position, Range, Location, etc.)
 * - Main entry point for the standalone LSP server binary (not imported here)
 * 
 * Architecture:
 *   transport.d  - Async message queue, stdio reader/writer threads
 *   dispatch.d   - Message routing and handler registration
 *   server.d     - LSP server orchestration and handlers
 *   protocol.d   - LSP protocol types (Position, Range, etc.)
 * 
 * The async architecture uses a producer-consumer pattern:
 *   StdioReader -> MessageQueue -> AsyncMessageLoop -> MessageDispatcher -> Handlers
 * 
 * Note: frontend.lsp.core.main is NOT imported here to avoid conflicts with
 * the main builder binary. It's only used in the LSP server build configuration.
 */
module frontend.lsp.core;

public import frontend.lsp.core.server;
public import frontend.lsp.core.protocol;
public import frontend.lsp.core.transport;
public import frontend.lsp.core.dispatch;
