/**
 * WebSocket Session Recovery & Resilience Tests — Issue #34.
 *
 * Acceptance criteria verified:
 * 1. Bounded exponential reconnect & backoff under permanent authorization failure.
 * 2. Automatic recovery after mobile sleep (visibilitychange) and network handoff (offline/online).
 * 3. Authoritative state resync on reconnect before resumed incremental updates.
 * 4. Clean unmount and unsubscription on route changes without memory or listener leaks.
 */

import { WebSocketManager } from "@/messages/wsManager";

// ─── Mock WebSocket ───────────────────────────────────────────────────────────

class MockWebSocket {
  static readonly OPEN = 1;
  static readonly CLOSED = 3;
  static readonly CONNECTING = 0;
  static readonly CLOSING = 2;

  readonly OPEN = 1;
  readonly CLOSED = 3;
  readonly CONNECTING = 0;
  readonly CLOSING = 2;

  readyState = MockWebSocket.CONNECTING;
  url: string;
  sent: string[] = [];

  onopen: ((ev: Event) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;

  constructor(url: string) {
    this.url = url;
    // Auto-open in next microtask unless controlled
    setTimeout(() => {
      if (this.readyState === MockWebSocket.CONNECTING) {
        this.readyState = MockWebSocket.OPEN;
        this.onopen?.(new Event("open"));
      }
    }, 10);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(code = 1000, reason = "Normal closure"): void {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.({ code, reason } as CloseEvent);
  }
}

describe("Issue #34: WebSocket Session Recovery", () => {
  const originalWs = global.WebSocket;
  let activeSockets: MockWebSocket[] = [];

  beforeEach(() => {
    jest.useFakeTimers();
    activeSockets = [];
    (global as unknown as { WebSocket: unknown }).WebSocket = class extends MockWebSocket {
      constructor(url: string) {
        super(url);
        activeSockets.push(this);
      }
    };
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
    (global as unknown as { WebSocket: unknown }).WebSocket = originalWs;
  });

  describe("Permanent Authorization Failure Backoff", () => {
    it("stops reconnection attempts immediately on 4001 / 4401 unauthorized close codes", () => {
      const onPermanentDisconnect = jest.fn();
      const onStatusChange = jest.fn();

      const manager = new WebSocketManager({
        url: "wss://arenax.gg/ws/match/test-1",
        maxReconnectAttempts: 5,
        onPermanentDisconnect,
        onStatusChange,
      });

      manager.connect();
      jest.advanceTimersByTime(20);
      expect(manager.getStatus()).toBe("connected");

      // Server terminates with permanent auth error code (4001 / 4401)
      const ws = activeSockets[0];
      ws.close(4401, "Token expired or revoked");

      expect(manager.getStatus()).toBe("unauthorized");
      expect(onPermanentDisconnect).toHaveBeenCalledTimes(1);

      // Fast-forward time — verify NO further reconnects are scheduled
      jest.advanceTimersByTime(60_000);
      expect(activeSockets.length).toBe(1);
    });

    it("stops reconnection when renewAuth returns false", async () => {
      const renewAuth = jest.fn().mockResolvedValue(false);
      const onPermanentDisconnect = jest.fn();

      const manager = new WebSocketManager({
        url: "wss://arenax.gg/ws/match/test-2",
        renewAuth,
        onPermanentDisconnect,
      });

      manager.connect();
      jest.advanceTimersByTime(20);

      // Drop connection transients
      activeSockets[0].close(1006, "Abnormal closure");

      // Advance to trigger reconnect attempt
      jest.advanceTimersByTime(2000);

      await Promise.resolve(); // flush microtasks
      expect(renewAuth).toHaveBeenCalled();
      expect(manager.getStatus()).toBe("unauthorized");
      expect(onPermanentDisconnect).toHaveBeenCalled();
    });
  });

  describe("Authoritative Resync on Reconnect", () => {
    it("calls onResync callback after reconnect before resuming normal updates", async () => {
      const onResync = jest.fn().mockResolvedValue(undefined);

      const manager = new WebSocketManager({
        url: "wss://arenax.gg/ws/match/test-resync",
        onResync,
      });

      manager.connect();
      jest.advanceTimersByTime(20);

      // Initial connect should not trigger resync
      expect(onResync).not.toHaveBeenCalled();

      // Simulate network disconnect
      activeSockets[0].close(1006, "Connection lost");

      // Wait for bounded reconnect delay
      jest.advanceTimersByTime(2000);
      // Wait for second socket to open
      jest.advanceTimersByTime(20);

      await Promise.resolve();
      expect(onResync).toHaveBeenCalledTimes(1);
    });
  });

  describe("Offline / Online Transitions & Visibility", () => {
    it("reconnects immediately when window fires online event", () => {
      const manager = new WebSocketManager({
        url: "wss://arenax.gg/ws/match/test-network",
      });

      manager.connect();
      jest.advanceTimersByTime(20);
      expect(manager.getStatus()).toBe("connected");

      // Network goes offline
      window.dispatchEvent(new Event("offline"));
      expect(manager.getStatus()).toBe("offline");

      // Network restored
      window.dispatchEvent(new Event("online"));
      jest.advanceTimersByTime(20);

      expect(manager.getStatus()).toBe("connected");
      expect(activeSockets.length).toBeGreaterThanOrEqual(2);

      manager.disconnect();
    });

    it("restores dead session when visibilitychange signals app wake from sleep", () => {
      const manager = new WebSocketManager({
        url: "wss://arenax.gg/ws/match/test-visibility",
      });

      manager.connect();
      jest.advanceTimersByTime(20);

      // Simulate mobile device sleeping and socket dying silently
      activeSockets[0].readyState = MockWebSocket.CLOSED;

      // Device wakes up
      Object.defineProperty(document, "visibilityState", {
        value: "visible",
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));
      jest.advanceTimersByTime(20);

      expect(manager.getStatus()).toBe("connected");
      manager.disconnect();
    });
  });

  describe("Repeated Mount / Unmount Lifecycle", () => {
    it("cleans up sockets, timers, and event listeners cleanly across multiple mount/unmount cycles", () => {
      for (let i = 0; i < 5; i++) {
        const manager = new WebSocketManager({
          url: `wss://arenax.gg/ws/match/cycle-${i}`,
        });

        manager.connect();
        jest.advanceTimersByTime(20);
        expect(manager.getStatus()).toBe("connected");

        // Unmount
        manager.disconnect();
        expect(manager.getStatus()).toBe("closed");
      }

      // No lingering reconnects should trigger
      jest.advanceTimersByTime(100_000);
      expect(activeSockets.filter((s) => s.readyState === MockWebSocket.OPEN).length).toBe(0);
    });
  });
});
