import { Logo } from "./brand.js";
import { ConnectButton } from "./components.js";
import { useAccount, useRoute } from "./hooks.js";
import { explorerAddress, network } from "./lib/config.js";
import { Buy } from "./pages/Buy.js";
import { Forecast } from "./pages/Forecast.js";
import { Leaderboard } from "./pages/Leaderboard.js";
import { Lock } from "./pages/Lock.js";
import { Overview } from "./pages/Overview.js";
import { Rewards } from "./pages/Rewards.js";
import { Rounds } from "./pages/Rounds.js";

const PAGES = [
  { route: "overview", label: "Overview", page: Overview },
  { route: "forecast", label: "Forecast", page: Forecast },
  { route: "buy", label: "Buy", page: Buy },
  { route: "lock", label: "Lock", page: Lock },
  { route: "rounds", label: "Rounds", page: Rounds },
  { route: "leaderboard", label: "Leaderboard", page: Leaderboard },
  { route: "rewards", label: "Rewards", page: Rewards },
] as const;

const REPO = "https://github.com/Tenax-Protocol/Tenax-Protocol";

export function App() {
  const route = useRoute();
  const { wrongNetwork } = useAccount();
  const current = PAGES.find((p) => p.route === route) ?? PAGES[0];
  const Page = current.page;

  return (
    <div className="app">
      {network.testnet && (
        <div className="testnet-bar">
          <strong>Testnet.</strong> This deployment runs on {network.chain.name}; its tokens have no value.
        </div>
      )}
      <header className="topbar">
        <div className="topbar-inner">
          <a href="#/" className="brand" aria-label="Tenax Protocol home">
            <Logo />
          </a>
          <nav className="nav" aria-label="Main">
            {PAGES.map((p) => (
              <a
                key={p.route}
                href={`#/${p.route}`}
                className={p.route === current.route ? "active" : ""}
                aria-current={p.route === current.route ? "page" : undefined}
              >
                {p.label}
              </a>
            ))}
          </nav>
          <div className="topbar-end">
            <span className="network">{network.chain.name}</span>
            <ConnectButton />
          </div>
        </div>
      </header>
      {wrongNetwork && <div className="banner">Switch your wallet to {network.chain.name} to continue.</div>}
      <main className="main">
        <Page />
      </main>
      <footer className="footer">
        <div className="footer-inner">
          <span>Tenax Protocol</span>
          <nav className="footer-links" aria-label="Resources">
            <a href={`${REPO}/blob/main/docs/WHITEPAPER.md`} target="_blank" rel="noreferrer">
              Whitepaper
            </a>
            <a href={`${REPO}/blob/main/docs/SECURITY.md`} target="_blank" rel="noreferrer">
              Security
            </a>
            <a href={REPO} target="_blank" rel="noreferrer">
              GitHub
            </a>
            <a href={explorerAddress(network.deployment.contracts.registry)} target="_blank" rel="noreferrer">
              Contracts
            </a>
          </nav>
        </div>
      </footer>
    </div>
  );
}
