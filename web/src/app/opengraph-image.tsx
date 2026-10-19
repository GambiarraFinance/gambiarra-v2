import { ImageResponse } from "next/og";

export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const alt =
  "Gambiarra Finance — DeFi de chinelo, cérebro de agente. Vault auto-composto na BSC.";

export default async function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#f6eedf",
          color: "#14110f",
          padding: "64px 72px",
          fontFamily: "sans-serif",
          position: "relative",
        }}
      >
        <div
          style={{
            position: "absolute",
            right: -130,
            top: -130,
            width: 560,
            height: 560,
            borderRadius: 9999,
            background: "#f7c948",
          }}
        />
        <div
          style={{
            position: "absolute",
            right: 130,
            bottom: -180,
            width: 420,
            height: 420,
            borderRadius: 9999,
            background: "#0e7a4b",
            opacity: 0.9,
          }}
        />

        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <div
            style={{
              width: 44,
              height: 44,
              borderRadius: 9999,
              background: "#0e7a4b",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "#f6eedf",
              fontSize: 24,
              fontWeight: 800,
            }}
          >
            G
          </div>
          <div style={{ fontSize: 28, fontWeight: 700, letterSpacing: -1 }}>gambiarra.finance</div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 18, maxWidth: 860 }}>
          <div style={{ fontSize: 22, letterSpacing: 4, textTransform: "uppercase", color: "#0e7a4b" }}>
            BSC · open source · agent-first
          </div>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              fontSize: 88,
              fontWeight: 800,
              lineHeight: 0.98,
              letterSpacing: -4,
            }}
          >
            DeFi de chinelo.
            <br />
            Cérebro de agente.
          </div>
          <div style={{ display: "flex", flexDirection: "column", fontSize: 26, color: "#3b342d", maxWidth: 720, lineHeight: 1.4 }}>
            Vault auto-composto sobre um MasterChef sem dono desde 2021 — com uma API feita para
            agentes autônomos.
          </div>
        </div>

        <div
          style={{
            display: "flex",
            gap: 32,
            fontSize: 20,
            letterSpacing: 2,
            textTransform: "uppercase",
            color: "#3b342d",
                      }}
        >
          <span>30 pools legados</span>
          <span>3 GAMB / bloco</span>
          <span>owner 0x0</span>
        </div>
      </div>
    ),
    size,
  );
}
