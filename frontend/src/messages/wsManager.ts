/**
 * WebSocket Connection Manager — Issue #697 / #34
 *
 * Features:
 * - Automatic reconnect with bounded exponential back-off + jitter
 * - Heartbeat / ping-pong keep-alive & mobile sleep / visibility recovery (#34)
 * - Permanent authorization failure backoff / abort (#34)
 * - Full authoritative resync on reconnect (#34)
 * - Auth token renewal support (#34)
 * - Clean unsubscribe and lifecycle cleanup on route change / unmount (#34)
 */

"use client";

// ─── Types ────────────────────────────────────────────────────────────────────

export type ConnectionStatus =
  | "idle"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "offline"
  | "unauthorized"
  | "closed";

export interface WsMessage<T = unknown> {
  /** Message category / event name */
  type: string;
  payload: T;
  /** Server-assigned message ID (optional) */
  id?: string;
  timestamp: number;
}

export interface WsConnectionConfig {
  url: string;
  /** JWT token for auth handshake */
  getToken?: () => string | null;
  /** Optional token renewal handler called upon auth failure / reconnect */
  renewAuth?: () => Promise<string | null | boolean>;
  /** Heartbeat interval in ms (default: 25 000) */
  heartbeatIntervalMs?: number;
  /** Max reconnect attempts before giving up (default: 10) */
  maxReconnectAttempts?: number;
  /** Base reconnect delay in ms (default: 500) */
  reconnectBaseDelayMs?: number;
  /** Max reconnect delay cap in ms (default: 30 000) */
  reconnectMaxDelayMs?: number;
  /** Called when a message arrives */
  onMessage?: (msg: WsMessage) => void;
  /** Called on connection status change */
  onStatusChange?: (status: ConnectionStatus) => void;
  /** Called when permanently disconnected */
  onPermanentDisconnect?: () => void;
  /** Called on successful reconnect to refresh authoritative application state */
  onResync?: () => Promise<void> | void;
}

export interface ConnectionMetrics {
  connectedAt: number | null;
  disconnections: number;
  reconnectAttempts: number;
  messagesReceived: number;
  messagesSent: number;
  lastHeartbeatAt: number | null;
}

// ─── Analytics ────────────────────────────────────────────────────────────────

export interface WsAnalyticsEvent {
  type: string;
  detail?: string;
  timestamp: number;
}

const _wsEvents: WsAnalyticsEvent[] = [];

function trackWsEvent(type: string, detail?: string): void {
  _wsEvents.unshift({ type, detail, timestamp: Date.now() });
  if (_wsEvents.length > 200) _wsEvents.length = 200;
}

export function getWsEvents(): readonly WsAnalyticsEvent[] {
  return _wsEvents;
}

export function clearWsEvents(): void {
  _wsEvents.length = 0;
}

const PERMANENT_AUTH_CODES = [1008, 4001, 4003, 4401, 4403];

// ─── Connection Manager ───────────────────────────────────────────────────────

export class WebSocketManager {
  private ws: WebSocket | null = null;
  private status: ConnectionStatus = "idle";
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private pongTimer: ReturnType<typeof setTimeout> | null = null;
  private explicitClose = false;
  private listenersAttached = false;

  private readonly metrics: ConnectionMetrics = {
    connectedAt: null,
    disconnections: 0,
    reconnectAttempts: 0,
    messagesReceived: 0,
    messagesSent: 0,
    lastHeartbeatAt: null,
  };

  private readonly config: Required<WsConnectionConfig>;

  constructor(config: WsConnectionConfig) {
    this.config = {
      getToken: () => null,
      renewAuth: async () => null,
      heartbeatIntervalMs: 25_000,
      maxReconnectAttempts: 10,
      reconnectBaseDelayMs: 500,
      reconnectMaxDelayMs: 30_000,
      onMessage: () => {},
      onStatusChange: () => {},
      onPermanentDisconnect: () => {},
      onResync: async () => {},
      ...config,
    };

    this.attachDomListeners();
  }

  // ─── Public API ─────────────────────────────────────────────────────────────

  connect(): void {
    this.explicitClose = false;
    this.openSocket();
  }

  disconnect(): void {
    this.explicitClose = true;
    this.cleanup();
    this.detachDomListeners();
    this.setStatus("closed");
    trackWsEvent("explicit_disconnect");
  }

  send<T>(type: string, payload: T): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    try {
      const msg: WsMessage<T> = { type, payload, timestamp: Date.now() };
      this.ws.send(JSON.stringify(msg));
      this.metrics.messagesSent++;
      return true;
    } catch {
      return false;
    }
  }

  getStatus(): ConnectionStatus {
    return this.status;
  }

  getMetrics(): Readonly<ConnectionMetrics> {
    return { ...this.metrics };
  }

  // ─── Lifecycle & Network Handlers (#34) ──────────────────────────────────────

  private handleVisibilityChange = (): void => {
    if (typeof document !== "undefined" && document.visibilityState === "visible") {
      if (!this.ws || this.ws.readyState === WebSocket.CLOSED) {
        if (this.status !== "unauthorized" && !this.explicitClose) {
          trackWsEvent("visibility_reconnect");
          this.reconnectAttempt = 0;
          this.openSocket();
        }
      } else if (this.ws.readyState === WebSocket.OPEN) {
        // Fast ping to verify socket isn't dead
        this.send("ping", { timestamp: Date.now() });
      }
    }
  };

  private handleOnline = (): void => {
    if (this.status !== "unauthorized" && !this.explicitClose) {
      trackWsEvent("network_online_reconnect");
      this.reconnectAttempt = 0;
      this.openSocket();
    }
  };

  private handleOffline = (): void => {
    trackWsEvent("network_offline");
    this.setStatus("offline");
  };

  private attachDomListeners(): void {
    if (typeof window === "undefined" || this.listenersAttached) return;
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
    window.addEventListener("online", this.handleOnline);
    window.addEventListener("offline", this.handleOffline);
    this.listenersAttached = true;
  }

  private detachDomListeners(): void {
    if (typeof window === "undefined" || !this.listenersAttached) return;
    document.removeEventListener("visibilitychange", this.handleVisibilityChange);
    window.removeEventListener("online", this.handleOnline);
    window.removeEventListener("offline", this.handleOffline);
    this.listenersAttached = false;
  }

  // ─── Internal Socket Handling ───────────────────────────────────────────────

  private async openSocket(): Promise<void> {
    const wasReconnecting = this.reconnectAttempt > 0;
    this.setStatus(wasReconnecting ? "reconnecting" : "connecting");
    trackWsEvent("connecting", this.config.url);

    // Optional auth renewal if reconnecting
    if (wasReconnecting && this.config.renewAuth) {
      try {
        const renewed = await this.config.renewAuth();
        if (renewed === false) {
          this.setStatus("unauthorized");
          trackWsEvent("permanent_disconnect", "renew_auth_failed");
          this.config.onPermanentDisconnect();
          return;
        }
      } catch {
        // Continue with current token
      }
    }

    let url = this.config.url;
    const token = this.config.getToken();
    if (token) {
      const separator = url.includes("?") ? "&" : "?";
      url = `${url}${separator}token=${encodeURIComponent(token)}`;
    }

    try {
      this.ws = new WebSocket(url);
    } catch (err) {
      trackWsEvent("open_error", String(err));
      this.scheduleReconnect();
      return;
    }

    this.ws.onopen = async () => {
      this.reconnectAttempt = 0;
      this.metrics.connectedAt = Date.now();
      this.setStatus("connected");
      this.startHeartbeat();
      trackWsEvent("connected", this.config.url);

      if (wasReconnecting && this.config.onResync) {
        try {
          await this.config.onResync();
          trackWsEvent("resync_completed");
        } catch (err) {
          trackWsEvent("resync_error", String(err));
        }
      }
    };

    this.ws.onmessage = (event: MessageEvent) => {
      this.metrics.messagesReceived++;
      try {
        const data = JSON.parse(event.data as string) as WsMessage;

        // Keepalive responses
        if (data.type === "pong" || data.type === "heartbeat") {
          this.metrics.lastHeartbeatAt = Date.now();
          if (this.pongTimer) {
            clearTimeout(this.pongTimer);
            this.pongTimer = null;
          }
          return;
        }

        // Auth rejection
        if (data.type === "auth_error") {
          this.setStatus("unauthorized");
          trackWsEvent("permanent_disconnect", "auth_error_message");
          this.cleanup();
          this.config.onPermanentDisconnect();
          return;
        }

        this.config.onMessage(data);
      } catch {
        // Non-JSON frame
      }
    };

    this.ws.onerror = () => {
      trackWsEvent("socket_error");
    };

    this.ws.onclose = (event: CloseEvent) => {
      this.stopHeartbeat();
      this.metrics.disconnections++;
      trackWsEvent("disconnected", `code=${event.code}`);

      if (this.explicitClose) {
        this.setStatus("closed");
        return;
      }

      // Permanent authorization failures: stop reconnecting (#34)
      if (PERMANENT_AUTH_CODES.includes(event.code)) {
        this.setStatus("unauthorized");
        trackWsEvent("permanent_disconnect", `auth_failure_code=${event.code}`);
        this.config.onPermanentDisconnect();
        return;
      }

      this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    if (this.reconnectAttempt >= this.config.maxReconnectAttempts) {
      this.setStatus("offline");
      trackWsEvent("permanent_disconnect", `attempts=${this.reconnectAttempt}`);
      this.config.onPermanentDisconnect();
      return;
    }

    const delay = this.calcDelay(this.reconnectAttempt);
    this.reconnectAttempt++;
    this.metrics.reconnectAttempts++;
    this.setStatus("reconnecting");
    trackWsEvent("reconnect_scheduled", `attempt=${this.reconnectAttempt} delay=${delay}`);

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
  }

  private calcDelay(attempt: number): number {
    const jitter = Math.random() * 300;
    const delay = this.config.reconnectBaseDelayMs * Math.pow(2, attempt) + jitter;
    return Math.min(delay, this.config.reconnectMaxDelayMs);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        try {
          this.ws.send(JSON.stringify({ type: "ping", timestamp: Date.now() }));
          this.metrics.lastHeartbeatAt = Date.now();

          this.pongTimer = setTimeout(() => {
            trackWsEvent("heartbeat_timeout");
            this.ws?.close(4000, "Heartbeat timeout");
          }, 8_000);
        } catch {
          // ignore send errors
        }
      }
    }, this.config.heartbeatIntervalMs);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
    if (this.pongTimer) {
      clearTimeout(this.pongTimer);
      this.pongTimer = null;
    }
  }

  private cleanup(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onmessage = null;
      this.ws.onerror = null;
      this.ws.onclose = null;
      if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) {
        this.ws.close(1000, "Explicit disconnect");
      }
      this.ws = null;
    }
  }

  private setStatus(status: ConnectionStatus): void {
    if (this.status === status) return;
    this.status = status;
    this.config.onStatusChange(status);
  }
}
