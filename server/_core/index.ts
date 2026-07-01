import "dotenv/config";
import express from "express";
import { initExternalDb } from "../db-external";
import { createServer } from "http";
import net from "net";
import { createExpressMiddleware } from "@trpc/server/adapters/express";
import { registerOAuthRoutes } from "./oauth";
import { registerGoogleOAuthCallback } from "../googleOAuthCallback";
import { registerUploadRoutes } from "../uploadRoutes";
import { appRouter } from "../routers";
import { createContext } from "./context";
import { serveStatic, setupVite } from "./vite";
import { scheduleDailyRaioXSync } from "../raioXCacheSync";
import { startSyncScheduler } from "../syncEngine";
import { startFinConfigScheduler } from "../finConfigScheduler";

function isPortAvailable(port: number): Promise<boolean> {
  return new Promise(resolve => {
    const server = net.createServer();
    server.listen(port, () => {
      server.close(() => resolve(true));
    });
    server.on("error", () => resolve(false));
  });
}

async function findAvailablePort(startPort: number = 3000): Promise<number> {
  for (let port = startPort; port < startPort + 20; port++) {
    if (await isPortAvailable(port)) {
      return port;
    }
  }
  throw new Error(`No available port found starting from ${startPort}`);
}

// Inicializar banco externo (SSH tunnel) antes de iniciar o servidor
initExternalDb().catch(err => console.error("[DB External] Init error:", err));

async function startServer() {
  const app = express();
  const server = createServer(app);
  // Configure body parser with larger size limit for file uploads
  app.use(express.json({ limit: "50mb" }));
  app.use(express.urlencoded({ limit: "50mb", extended: true }));
  // Health check endpoint (para Docker, Nginx e monitoramento)
  app.get("/health", (_req, res) => {
    res.status(200).json({ status: "ok", uptime: process.uptime(), timestamp: new Date().toISOString() });
  });
  // OAuth callback under /api/oauth/callback
  registerOAuthRoutes(app);
  // Google Business Profile OAuth callback
  registerGoogleOAuthCallback(app);
  // Upload routes (art image reference, etc.)
  registerUploadRoutes(app);
  // RTSP → WebSocket proxy para câmeras IP do VIP Cam
  const { registerRtspProxyRoutes } = await import("../rtspProxy");
  await registerRtspProxyRoutes(app, server);
  // tRPC API
  app.use(
    "/api/trpc",
    createExpressMiddleware({
      router: appRouter,
      createContext,
    })
  );
  // development mode uses Vite, production mode uses static files
  if (process.env.NODE_ENV === "development") {
    await setupVite(app, server);
  } else {
    serveStatic(app);
  }

  const preferredPort = parseInt(process.env.PORT || "3000");
  // Em produção (Docker), usa a porta exata; em dev, tenta ports alternativos
  const port = process.env.NODE_ENV === "production"
    ? preferredPort
    : await findAvailablePort(preferredPort);

  if (port !== preferredPort) {
    console.log(`Port ${preferredPort} is busy, using port ${port} instead`);
  }

  server.listen(port, "0.0.0.0", () => {
    console.log(`Server running on http://localhost:${port}/`);
    // Agendar sync noturna do cache persistente do Raio-X (02:00 BRT = 05:00 UTC)
    scheduleDailyRaioXSync();
    // Iniciar sincronização incremental a cada 30 minutos
    startSyncScheduler();
    // Agendar job mensal de taxas de cartão (dia 1 de cada mês às 06:00 BRT = 09:00 UTC)
    startFinConfigScheduler();
  });
}

startServer().catch(console.error);
