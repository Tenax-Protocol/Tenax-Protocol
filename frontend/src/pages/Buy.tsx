import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { parseEther } from "viem";
import { Mark } from "../brand.js";
import { Card, ConnectPrompt, PageHeader, TxStatus } from "../components.js";
import { useProtocol, usePosition } from "../data.js";
import { useAccount, useTx } from "../hooks.js";
import { publicClient } from "../lib/client.js";
import { network } from "../lib/config.js";
import { formatBps, formatEth, formatToken } from "../lib/format.js";
import { encodeBuy, quoterAbi, universalRouterAbi, withSlippage } from "../lib/swap.js";

const SLIPPAGE_BPS = 100n;

function parseAmount(text: string): bigint | null {
  try {
    const value = parseEther(text.trim() || "0");
    return value > 0n ? value : null;
  } catch {
    return null;
  }
}

export function Buy() {
  const { address } = useAccount();
  const position = usePosition(address);
  const protocol = useProtocol();
  const [text, setText] = useState("0.01");
  const amount = parseAmount(text);
  const { run, state } = useTx();
  const pool = network.deployment.poolKey;

  const quote = useQuery({
    queryKey: ["quote", amount?.toString()],
    enabled: amount !== null,
    refetchInterval: 15_000,
    queryFn: async () => {
      const { result } = await publicClient.simulateContract({
        address: network.uniswap.quoter,
        abi: quoterAbi,
        functionName: "quoteExactInputSingle",
        args: [{ poolKey: pool, zeroForOne: true, exactAmount: amount!, hookData: "0x" }],
      });
      return result[0];
    },
  });

  if (!address) return <ConnectPrompt what="buy TENAX" />;

  const buy = () =>
    run(async (wallet) => {
      const block = await publicClient.getBlock();
      const args = encodeBuy(pool, amount!, withSlippage(quote.data!, SLIPPAGE_BPS), block.timestamp + 600n);
      return wallet.writeContract({
        account: address,
        chain: network.chain,
        address: network.uniswap.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        args: [args.commands, args.inputs, args.deadline],
        value: amount!,
      });
    }, "TENAX bought.");

  const insufficient = amount !== null && position.data !== undefined && amount > position.data.eth;
  const minOut = quote.data !== undefined ? withSlippage(quote.data, SLIPPAGE_BPS) : undefined;
  const price = amount !== null && quote.data ? Number(quote.data) / Number(amount) : undefined;

  return (
    <>
      <PageHeader title="Buy TENAX">
        Swap ETH for TENAX in the protocol's Uniswap v4 pool. The pool's liquidity is owned by the protocol and cannot
        be withdrawn.
      </PageHeader>
      <div className="split">
        <section className="card swap">
          <div className="swap-box">
            <div className="swap-row">
              <span className="muted small">You pay</span>
              <span className="muted small">Balance {position.data ? formatEth(position.data.eth, 4) : "..."}</span>
            </div>
            <div className="swap-row">
              <input
                className="swap-input"
                inputMode="decimal"
                value={text}
                onChange={(e) => setText(e.target.value)}
                aria-label="ETH to spend"
              />
              <span className="token-pill">
                <span className="token-icon eth">{"Ξ"}</span>ETH
              </span>
            </div>
            <div className="swap-presets">
              {["0.005", "0.01", "0.05"].map((v) => (
                <button key={v} className={`preset${text === v ? " active" : ""}`} onClick={() => setText(v)}>
                  {v} ETH
                </button>
              ))}
            </div>
          </div>
          <div className="swap-arrow" aria-hidden>
            <svg viewBox="0 0 24 24">
              <path d="M12 5v14M6 13l6 6 6-6" />
            </svg>
          </div>
          <div className="swap-box">
            <div className="swap-row">
              <span className="muted small">You receive</span>
              <span className="muted small">Balance {position.data ? formatToken(position.data.tenax) : "..."}</span>
            </div>
            <div className="swap-row">
              <span className="swap-output">{quote.data !== undefined ? formatToken(quote.data) : "0.00"}</span>
              <span className="token-pill">
                <Mark className="token-icon tenax" />
                TENAX
              </span>
            </div>
          </div>
          <dl className="rows details">
            <div>
              <dt>Rate</dt>
              <dd className="num">
                {price ? `1 ETH = ${price.toLocaleString("en-US", { maximumFractionDigits: 0 })} TENAX` : "-"}
              </dd>
            </div>
            <div>
              <dt>Minimum received</dt>
              <dd className="num">{minOut !== undefined ? `${formatToken(minOut)} TENAX` : "-"}</dd>
            </div>
            <div>
              <dt>Pool fee now</dt>
              <dd className="num">{protocol.data ? formatBps(protocol.data.launchFee / 100, 2) : "-"}</dd>
            </div>
            <div>
              <dt>Slippage limit</dt>
              <dd className="num">1%</dd>
            </div>
          </dl>
          <button
            className="button primary large block"
            disabled={amount === null || quote.data === undefined || insufficient || state.status === "pending"}
            onClick={buy}
          >
            {insufficient ? "Not enough ETH" : amount === null ? "Enter an amount" : "Buy TENAX"}
          </button>
          <TxStatus state={state} />
        </section>
        <aside className="side">
          <Card title="How much do I need?">
            <p className="muted">
              Forecasting needs 5,000 veTENAX. A lock for the maximum 104 weeks gives about as much veTENAX as TENAX
              locked, and it decays over time, so roughly 5,500 TENAX keeps you forecasting for 60 days. The{" "}
              <a href="#/lock">Lock</a> page shows the exact amount.
            </p>
          </Card>
          <Card title="Where the fee goes">
            <p className="muted">
              Buys pay the pool fee in ETH: 40% to skilled forecasters, 40% to veTENAX holders and 20% to the treasury.
              Sells pay it in TENAX, which is burned. The fee starts at 20% at launch and falls to 0.3% over the first
              300 blocks.
            </p>
          </Card>
          <Card title="Test ETH">
            <p className="muted">
              <a href="https://console.optimism.io/faucet" target="_blank" rel="noreferrer">
                Superchain faucet
              </a>{" "}
              or{" "}
              <a href="https://portal.cdp.coinbase.com/products/faucet" target="_blank" rel="noreferrer">
                Coinbase faucet
              </a>
              , both free for {network.chain.name}.
            </p>
          </Card>
        </aside>
      </div>
    </>
  );
}
