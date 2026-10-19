import { ImageResponse } from "next/og";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";
export const alt = "Gambiarra Finance";

export default async function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0e7a4b",
          color: "#f6eedf",
          fontFamily: "sans-serif",
          position: "relative",
        }}
      >
        <div
          style={{
            position: "absolute",
            width: 132,
            height: 132,
            borderRadius: 9999,
            border: "10px solid rgba(246, 238, 223, 0.28)",
          }}
        />
        <div style={{ display: "flex", fontSize: 108, fontWeight: 800, letterSpacing: -6, lineHeight: 1 }}>
          g<span style={{ color: "#f7c948" }}>.</span>
        </div>
      </div>
    ),
    size,
  );
}
