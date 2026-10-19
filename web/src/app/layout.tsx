import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, DM_Sans, Space_Mono } from "next/font/google";
import "./globals.css";

const bricolage = Bricolage_Grotesque({
  variable: "--font-bricolage",
  subsets: ["latin"],
  display: "swap",
});

const dmSans = DM_Sans({
  variable: "--font-dm-sans",
  subsets: ["latin"],
  display: "swap",
});

const spaceMono = Space_Mono({
  variable: "--font-space-mono",
  subsets: ["latin"],
  weight: ["400", "700"],
  display: "swap",
});

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "https://gambiarra.finance";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: "Gambiarra Finance — DeFi de chinelo, infra de agente",
    template: "%s · Gambiarra Finance",
  },
  description:
    "Um vault auto-composto sobre o MasterChef da Gambiarra Finance na BSC — contrato sem dono desde 2021, agora com uma camada nova e uma API feita para agentes autônomos.",
  applicationName: "Gambiarra Finance",
  keywords: [
    "Gambiarra Finance",
    "DeFi BSC",
    "agentes autônomos",
    "vault auto-compounder",
    "GAMB",
    "MasterChef",
    "x402",
    "agentic finance",
    "DeFi open source",
  ],
  authors: [{ name: "codingsh", url: "https://github.com/GambiarraFinance" }],
  creator: "codingsh",
  publisher: "Gambiarra Finance",
  alternates: {
    canonical: "/",
  },
  openGraph: {
    type: "website",
    locale: "pt_BR",
    url: "/",
    siteName: "Gambiarra Finance",
    title: "Gambiarra Finance — DeFi de chinelo, infra de agente",
    description:
      "O MasterChef que ninguém pode desligar virou base de um vault auto-composto e de uma API agent-first na BSC.",
  },
  twitter: {
    card: "summary_large_image",
    title: "Gambiarra Finance — DeFi de chinelo, infra de agente",
    description:
      "Vault auto-composto, oráculo TWAP e uma API feita para agentes. Open source, na BSC.",
    creator: "@codingsh",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
  category: "finance",
};

export const viewport: Viewport = {
  themeColor: "#f6eedf",
  colorScheme: "light",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="pt-BR"
      data-scroll-behavior="smooth"
      className={`${bricolage.variable} ${dmSans.variable} ${spaceMono.variable} h-full antialiased`}
    >
      <body className="grain min-h-full flex flex-col">
        <a
          href="#conteudo"
          className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[60] focus:rounded-full focus:bg-ink focus:px-5 focus:py-3 focus:text-sand"
        >
          Pular para o conteúdo
        </a>
        {children}
      </body>
    </html>
  );
}
